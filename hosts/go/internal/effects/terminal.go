package effects

import (
	"os"
	"time"
)

func (e *Effects) env(r *request) (object, error) {
	if value, found := os.LookupEnv(r.Name); found {
		return object{"value": value}, nil
	}
	return object{"value": nil}, nil
}

// clock reads the wall clock and a monotonic clock whose origin is the start
// of the run.
func (e *Effects) clock(*request) (object, error) {
	return object{
		"wallMs":      time.Now().UnixMilli(),
		"monotonicUs": time.Since(e.origin).Microseconds(),
	}, nil
}

func (e *Effects) output(r *request) (object, error) {
	data, err := decode("data", r.Data)
	if err != nil {
		return nil, err
	}
	stream := e.stdout
	if r.Stream == "stderr" {
		stream = e.stderr
	}
	if _, err := stream.Write(data); err != nil {
		return nil, err
	}
	return object{}, nil
}

// input is standard input read so far by a background reader.
type input struct {
	buffered []byte
	ended    bool
}

// readInput returns at most max bytes of standard input, waiting for at
// least one; eof is true once the stream is exhausted and data is empty.
func (e *Effects) readInput(r *request) (object, error) {
	e.mu.Lock()
	if e.input == nil {
		e.input = &input{}
		go e.readStdin(e.input)
	}
	in := e.input
	e.mu.Unlock()
	e.waitFor(func() bool { return len(in.buffered) > 0 || in.ended }, -1)
	e.mu.Lock()
	defer e.mu.Unlock()
	taken := min(int64(len(in.buffered)), max(1, r.Max))
	data := in.buffered[:taken]
	in.buffered = in.buffered[taken:]
	return object{"data": encode(data), "eof": taken == 0 && in.ended}, nil
}

func (e *Effects) readStdin(in *input) {
	buffer := make([]byte, 64*1024)
	for {
		n, err := e.stdin.Read(buffer)
		e.mu.Lock()
		in.buffered = append(in.buffered, buffer[:n]...)
		if err != nil {
			in.ended = true
		}
		e.wake()
		e.mu.Unlock()
		if err != nil {
			return
		}
	}
}

// terminal reports whether one of the run's standard streams is a terminal
// and, for an output stream that is one, its width. A stream that is not an
// operating-system file (an embedder's buffer, through WithStdio) is not a
// terminal.
func (e *Effects) terminal(r *request) (object, error) {
	var stream any
	switch r.Stream {
	case "stdin":
		stream = e.stdin
	case "stdout":
		stream = e.stdout
	case "stderr":
		stream = e.stderr
	default:
		return nil, newError(kindInvalid, "unknown stream %q", r.Stream)
	}
	file, isFile := stream.(interface{ Fd() uintptr })
	if !isFile {
		return object{"terminal": false, "columns": nil}, nil
	}
	attached, columns := terminalOf(file.Fd())
	if !attached || r.Stream == "stdin" || columns <= 0 {
		return object{"terminal": attached, "columns": nil}, nil
	}
	return object{"terminal": true, "columns": columns}, nil
}
