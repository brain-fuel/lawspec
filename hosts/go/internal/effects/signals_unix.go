//go:build unix

package effects

import (
	"os"
	"syscall"

	"golang.org/x/sys/unix"
)

// signalName is the conventional name of a signal, such as SIGTERM, as
// Node reports it.
func signalName(signal syscall.Signal) string {
	if name := unix.SignalName(signal); name != "" {
		return name
	}
	return signal.String()
}

func terminate(p *os.Process) error {
	return p.Signal(syscall.SIGTERM)
}
