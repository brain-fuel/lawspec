package effects

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// process is one spawned program and the events not yet polled.
type process struct {
	cmd    *exec.Cmd
	events []object
	exited bool
}

// lookPath finds a program as execvp does: a name with a slash is used as
// given; any other name is searched for in the PATH of the environment the
// program will run with, as Node's spawn does.
func lookPath(program string, environment []string) (string, error) {
	if strings.Contains(program, "/") {
		return program, nil
	}
	search := ""
	for _, entry := range environment {
		if value, found := strings.CutPrefix(entry, "PATH="); found {
			search = value
		}
	}
	for _, directory := range filepath.SplitList(search) {
		if directory == "" {
			directory = "."
		}
		candidate := filepath.Join(directory, program)
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
			return candidate, nil
		}
	}
	return "", newError(kindNotFound, "spawn %s ENOENT: executable file not found in PATH", program)
}

// spawn starts argv[0] without a shell in cwd. A null env inherits the
// host's environment; an object replaces it. stdin is written and then
// closed.
func (e *Effects) spawn(r *request) (object, error) {
	if len(r.Argv) == 0 {
		return nil, newError(kindInvalid, "spawn needs a program")
	}
	directory, err := absolute(r.Cwd)
	if err != nil {
		return nil, err
	}
	// An explicit environment, so that exec adds no PWD of its own.
	environment := os.Environ()
	if r.Env != nil {
		environment = make([]string, 0, len(r.Env))
		for name, value := range r.Env {
			environment = append(environment, name+"="+value)
		}
	}
	var stdin []byte
	if r.Stdin != nil {
		if stdin, err = decode("stdin", r.Stdin); err != nil {
			return nil, err
		}
	}
	program, err := lookPath(r.Argv[0], environment)
	if err != nil {
		return nil, err
	}
	cmd := &exec.Cmd{Path: program, Args: r.Argv, Dir: directory, Env: environment}
	input, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	go func() {
		// A program that exits without reading its input is not an error.
		input.Write(stdin)
		input.Close()
	}()

	e.mu.Lock()
	handle := e.nextID()
	p := &process{cmd: cmd}
	e.processes[handle] = p
	e.mu.Unlock()

	done := make(chan struct{}, 2)
	collect := func(stream string, from io.Reader) {
		buffer := make([]byte, 64*1024)
		for {
			n, err := from.Read(buffer)
			if n > 0 {
				chunk := encode(buffer[:n])
				e.mu.Lock()
				p.events = append(p.events, object{"handle": handle, "stream": stream, "data": chunk})
				e.wake()
				e.mu.Unlock()
			}
			if err != nil {
				done <- struct{}{}
				return
			}
		}
	}
	go collect("stdout", stdout)
	go collect("stderr", stderr)
	go func() {
		// The exit event follows the last chunk of both streams, as Node's
		// close event does.
		<-done
		<-done
		// Wait's error repeats what ProcessState records.
		cmd.Wait()
		event := exitEvent(handle, cmd.ProcessState)
		e.mu.Lock()
		p.exited = true
		p.events = append(p.events, event)
		e.wake()
		e.mu.Unlock()
	}()
	return object{"handle": handle}, nil
}

func exitEvent(handle int64, state *os.ProcessState) object {
	if status, ok := state.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		return object{"handle": handle, "signal": signalName(status.Signal())}
	}
	return object{"handle": handle, "exit": state.ExitCode()}
}

func (e *Effects) knownProcess(handle int64) (*process, error) {
	p, found := e.processes[handle]
	if !found {
		return nil, newError(kindInvalid, "unknown process handle %d", handle)
	}
	return p, nil
}

// poll waits up to timeoutMs until any listed process has events, then
// returns every event available, possibly none.
func (e *Effects) poll(r *request) (object, error) {
	e.mu.Lock()
	entries := make([]*process, 0, len(r.Handles))
	for _, handle := range r.Handles {
		p, err := e.knownProcess(handle)
		if err != nil {
			e.mu.Unlock()
			return nil, err
		}
		entries = append(entries, p)
	}
	e.mu.Unlock()
	e.waitFor(func() bool {
		for _, p := range entries {
			if len(p.events) > 0 {
				return true
			}
		}
		return false
	}, milliseconds(r.TimeoutMs))
	e.mu.Lock()
	defer e.mu.Unlock()
	events := []object{}
	for _, p := range entries {
		events = append(events, p.events...)
		p.events = nil
	}
	return object{"events": events}, nil
}

// kill sends SIGTERM to a running process; a finished one is a success.
func (e *Effects) kill(r *request) (object, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	p, err := e.knownProcess(r.Handle)
	if err != nil {
		return nil, err
	}
	if !p.exited {
		if err := terminate(p.cmd.Process); err != nil && !errors.Is(err, os.ErrProcessDone) {
			return nil, err
		}
	}
	return object{}, nil
}

// milliseconds is a non-negative timeout.
func milliseconds(timeout int64) time.Duration {
	return time.Duration(max(0, timeout)) * time.Millisecond
}
