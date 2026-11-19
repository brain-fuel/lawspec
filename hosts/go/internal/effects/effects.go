// Package effects performs the primitive effects of the LawSpec host-effect
// ABI (docs/reference/host-effects.md) for the Go host. It decides nothing
// about LawSpec: it decodes one request, performs that primitive with Go's
// standard library, and encodes the typed result. Errors are results; no
// panic or Go error crosses the boundary. The Node reference host is
// templates/hosts/node/host.mjs; this package keeps its semantics and error
// kinds. ref:DEC-host-effect-abi
package effects

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"sync"
	"syscall"
	"time"
)

// ABI is the envelope version this host speaks.
const ABI = 2

// Error kinds the core acts on.
const (
	kindNotFound          = "not-found"
	kindAlreadyExists     = "already-exists"
	kindPermissionDenied  = "permission-denied"
	kindNotADirectory     = "not-a-directory"
	kindIsADirectory      = "is-a-directory"
	kindDirectoryNotEmpty = "directory-not-empty"
	kindDenied            = "denied"
	kindUnsupported       = "unsupported"
	kindInvalid           = "invalid"
	kindFailed            = "failed"
)

// hostError is a failure with the kind the core acts on.
type hostError struct {
	kind    string
	message string
}

func (e *hostError) Error() string { return e.message }

func newError(kind, format string, args ...any) error {
	return &hostError{kind: kind, message: fmt.Sprintf(format, args...)}
}

// kindOf classifies an operating-system failure as Node's host does by its
// error code.
func kindOf(err error) string {
	var typed *hostError
	if errors.As(err, &typed) {
		return typed.kind
	}
	var errno syscall.Errno
	if errors.As(err, &errno) {
		switch errno {
		case syscall.ENOENT:
			return kindNotFound
		case syscall.EEXIST:
			return kindAlreadyExists
		case syscall.EADDRINUSE:
			// serve: the port is taken.
			return kindAlreadyExists
		case syscall.EACCES, syscall.EPERM:
			return kindPermissionDenied
		case syscall.ENOTDIR:
			return kindNotADirectory
		case syscall.EISDIR:
			return kindIsADirectory
		case syscall.ENOTEMPTY:
			return kindDirectoryNotEmpty
		}
	}
	switch {
	case errors.Is(err, fs.ErrNotExist), errors.Is(err, exec.ErrNotFound):
		return kindNotFound
	case errors.Is(err, fs.ErrExist):
		return kindAlreadyExists
	case errors.Is(err, fs.ErrPermission):
		return kindPermissionDenied
	}
	return kindFailed
}

// request is the union of every operation's fields. Pointer and raw fields
// distinguish an absent or null field from a zero value.
type request struct {
	ABI         *int              `json:"abi"`
	Op          string            `json:"op"`
	Path        *string           `json:"path"`
	Data        *string           `json:"data"`
	Mode        string            `json:"mode"`
	Permissions *int64            `json:"permissions"`
	From        *string           `json:"from"`
	To          *string           `json:"to"`
	Follow      bool              `json:"follow"`
	Recursive   bool              `json:"recursive"`
	Argv        []string          `json:"argv"`
	Cwd         *string           `json:"cwd"`
	Env         map[string]string `json:"env"`
	Stdin       *string           `json:"stdin"`
	Handles     []int64           `json:"handles"`
	Handle      int64             `json:"handle"`
	TimeoutMs   int64             `json:"timeoutMs"`
	URL         string            `json:"url"`
	Method      string            `json:"method"`
	Headers     [][]string        `json:"headers"`
	Body        *string           `json:"body"`
	Name        string            `json:"name"`
	Stream      string            `json:"stream"`
	Max         int64             `json:"max"`
	Port        int               `json:"port"`
	Listener    int64             `json:"listener"`
	Request     int64             `json:"request"`
	Status      int               `json:"status"`
	Policy      *policy           `json:"policy"`
}

// object is a JSON object reply.
type object = map[string]any

// Options are the standard streams the effects use. A nil field means the
// process's own stream.
type Options struct {
	Stdin  io.Reader
	Stdout io.Writer
	Stderr io.Writer
}

// Effects is the state of one core run: its processes, listeners and
// pending HTTP requests. Perform is called from one goroutine at a time;
// the goroutines it starts share the state under mu.
type Effects struct {
	stdin  io.Reader
	stdout io.Writer
	stderr io.Writer
	origin time.Time

	mu        sync.Mutex
	changed   chan struct{}
	next      int64
	processes map[int64]*process
	listeners map[int64]*listener
	requests  map[int64]*pending
	input     *input
	closed    bool
}

// New returns the effects of one run.
func New(options Options) *Effects {
	e := &Effects{
		stdin:     options.Stdin,
		stdout:    options.Stdout,
		stderr:    options.Stderr,
		origin:    time.Now(),
		changed:   make(chan struct{}),
		next:      1,
		processes: map[int64]*process{},
		listeners: map[int64]*listener{},
		requests:  map[int64]*pending{},
	}
	if e.stdin == nil {
		e.stdin = os.Stdin
	}
	if e.stdout == nil {
		e.stdout = os.Stdout
	}
	if e.stderr == nil {
		e.stderr = os.Stderr
	}
	return e
}

// nextID returns the next handle, listener or request number. Callers hold
// mu.
func (e *Effects) nextID() int64 {
	id := e.next
	e.next++
	return id
}

// wake tells every waiter that the state changed. Callers hold mu.
func (e *Effects) wake() {
	close(e.changed)
	e.changed = make(chan struct{})
}

// waitFor returns once ready holds or the timeout passes. ready runs with
// mu held. A negative timeout waits indefinitely.
func (e *Effects) waitFor(ready func() bool, timeout time.Duration) {
	var expired <-chan time.Time
	if timeout >= 0 {
		timer := time.NewTimer(timeout)
		defer timer.Stop()
		expired = timer.C
	}
	for {
		e.mu.Lock()
		if ready() {
			e.mu.Unlock()
			return
		}
		changed := e.changed
		e.mu.Unlock()
		select {
		case <-changed:
		case <-expired:
			return
		}
	}
}

// Perform answers one encoded request with one encoded reply.
func (e *Effects) Perform(encoded []byte) []byte {
	result, err := e.perform(encoded)
	var reply object
	if err != nil {
		reply = object{"abi": ABI, "error": object{"kind": kindOf(err), "message": err.Error()}}
	} else {
		reply = object{"abi": ABI, "ok": result}
	}
	bytes, err := json.Marshal(reply)
	if err != nil {
		bytes, _ = json.Marshal(object{"abi": ABI, "error": object{"kind": kindFailed, "message": err.Error()}})
	}
	return bytes
}

func (e *Effects) perform(encoded []byte) (object, error) {
	var r request
	if err := json.Unmarshal(encoded, &r); err != nil {
		return nil, newError(kindInvalid, "malformed request: %v", err)
	}
	if r.ABI == nil || *r.ABI != ABI {
		version := "missing"
		if r.ABI != nil {
			version = fmt.Sprint(*r.ABI)
		}
		return nil, newError(kindInvalid, "unsupported ABI version %s", version)
	}
	if !r.Policy.valid() {
		return nil, newError(kindInvalid, "the request has no valid policy")
	}
	operation, found := operations[r.Op]
	if !found {
		return nil, newError(kindUnsupported, "unknown operation %s", r.Op)
	}
	if err := enforce(r.Policy, &r); err != nil {
		return nil, err
	}
	return operation(e, &r)
}

// operations performs each op of the ABI.
var operations = map[string]func(*Effects, *request) (object, error){
	"read":     (*Effects).read,
	"write":    (*Effects).write,
	"list":     (*Effects).list,
	"stat":     (*Effects).stat,
	"realpath": (*Effects).realpath,
	"remove":   (*Effects).remove,
	"rename":   (*Effects).rename,
	"mkdirs":   (*Effects).mkdirs,
	"spawn":    (*Effects).spawn,
	"poll":     (*Effects).poll,
	"kill":     (*Effects).kill,
	"fetch":    (*Effects).fetch,
	"env":      (*Effects).env,
	"clock":    (*Effects).clock,
	"output":   (*Effects).output,
	"input":    (*Effects).readInput,
	"terminal": (*Effects).terminal,
	"serve":    (*Effects).serve,
	"accept":   (*Effects).accept,
	"respond":  (*Effects).respond,
}

// Close stops every process and listener the run started, as the Node host
// does when its worker finishes.
func (e *Effects) Close() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.closed = true
	for _, p := range e.processes {
		if !p.exited {
			p.cmd.Process.Kill()
		}
	}
	for _, l := range e.listeners {
		l.socket.Close()
		for conn := range l.conns {
			conn.Close()
		}
	}
	for id, p := range e.requests {
		close(p.cancel)
		delete(e.requests, id)
	}
	e.wake()
}

func encode(data []byte) string {
	return base64.StdEncoding.EncodeToString(data)
}

func decode(name string, text *string) ([]byte, error) {
	if text == nil {
		return nil, newError(kindInvalid, "%s must be a base64 string", name)
	}
	data, err := base64.StdEncoding.DecodeString(*text)
	if err != nil {
		return nil, newError(kindInvalid, "%s: %v", name, err)
	}
	return data, nil
}

// absolute returns the normalised absolute POSIX path of a request.
func absolute(file *string) (string, error) {
	if file == nil {
		return "", newError(kindInvalid, "path is not absolute: missing")
	}
	if !path.IsAbs(*file) {
		return "", newError(kindInvalid, "path is not absolute: %s", *file)
	}
	return path.Clean(*file), nil
}
