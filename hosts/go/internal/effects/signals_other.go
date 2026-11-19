//go:build !unix

package effects

import (
	"os"
	"syscall"
)

func signalName(signal syscall.Signal) string {
	return signal.String()
}

// terminate stops a process where there is no SIGTERM.
func terminate(p *os.Process) error {
	return p.Kill()
}
