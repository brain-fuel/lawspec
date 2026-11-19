//go:build !unix

package main

import "os"

func workingDirectory() (string, error) {
	return os.Getwd()
}
