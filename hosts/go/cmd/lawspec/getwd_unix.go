//go:build unix

package main

import "golang.org/x/sys/unix"

// workingDirectory is getcwd(3), the physical directory, as Node's
// process.cwd() and the native CLI report it. os.Getwd would prefer a
// logical $PWD through a symbolic link.
func workingDirectory() (string, error) {
	return unix.Getwd()
}
