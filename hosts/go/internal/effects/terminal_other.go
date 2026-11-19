//go:build !unix

package effects

// terminalOf reports no terminal where the host has no termios.
func terminalOf(uintptr) (bool, int) {
	return false, 0
}
