//go:build unix

package effects

import "golang.org/x/sys/unix"

// terminalOf is isatty(3), which asks for the terminal attributes, and the
// width the TIOCGWINSZ ioctl reports (0 when it cannot).
func terminalOf(descriptor uintptr) (bool, int) {
	if _, err := unix.IoctlGetTermios(int(descriptor), ioctlReadTermios); err != nil {
		return false, 0
	}
	size, err := unix.IoctlGetWinsize(int(descriptor), unix.TIOCGWINSZ)
	if err != nil {
		return true, 0
	}
	return true, int(size.Col)
}
