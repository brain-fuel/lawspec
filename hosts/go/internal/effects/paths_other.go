//go:build !darwin

package effects

// storedCase is the identity where the C library's realpath(3) does not
// change the case of names (on Linux, names are compared exactly).
func storedCase(file string) (string, error) {
	return file, nil
}
