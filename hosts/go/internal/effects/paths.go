package effects

import "path/filepath"

// realpath resolves a path to its canonical absolute form, as POSIX
// realpath(3) does: every symbolic link resolved and every component
// present. filepath.EvalSymlinks walks the path with lstat and readlink;
// storedCase then gives each name the case the file system stores, which
// the C library's realpath does on macOS and EvalSymlinks does not.
func (e *Effects) realpath(r *request) (object, error) {
	file, err := absolute(r.Path)
	if err != nil {
		return nil, err
	}
	resolved, err := filepath.EvalSymlinks(file)
	if err != nil {
		return nil, err
	}
	canonical, err := storedCase(resolved)
	if err != nil {
		return nil, err
	}
	return object{"path": canonical}, nil
}
