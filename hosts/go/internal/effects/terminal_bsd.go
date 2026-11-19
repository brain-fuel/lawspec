//go:build darwin || dragonfly || freebsd || netbsd || openbsd

package effects

import "golang.org/x/sys/unix"

// ioctlReadTermios reads a terminal's attributes, as tcgetattr(3) does.
const ioctlReadTermios = unix.TIOCGETA
