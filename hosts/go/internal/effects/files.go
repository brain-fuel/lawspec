package effects

import (
	"crypto/rand"
	"fmt"
	"io/fs"
	"os"
	"path"
	"syscall"
)

func (e *Effects) read(r *request) (object, error) {
	file, err := absolute(r.Path)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	return object{"data": encode(data)}, nil
}

// write writes a temporary sibling exclusively, then renames it over the
// path (replace) or hard-links it to the path (create), and always removes
// the temporary file. Missing parent directories are created. The temporary
// file is created with the request's permission bits (0666 without), less
// the umask, as open(2) creates it.
func (e *Effects) write(r *request) (object, error) {
	file, err := absolute(r.Path)
	if err != nil {
		return nil, err
	}
	data, err := decode("data", r.Data)
	if err != nil {
		return nil, err
	}
	if r.Mode != "replace" && r.Mode != "create" {
		return nil, newError(kindInvalid, "unknown write mode %q", r.Mode)
	}
	bits, err := permissions(r, 0o666)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(path.Dir(file), 0o777); err != nil {
		return nil, err
	}
	temporary := fmt.Sprintf("%s.lawspec-%s.tmp", file, rand.Text())
	defer os.Remove(temporary)
	if err := writeExclusive(temporary, data, bits); err != nil {
		return nil, err
	}
	if r.Mode == "create" {
		err = os.Link(temporary, file)
	} else {
		err = os.Rename(temporary, file)
	}
	if err != nil {
		return nil, err
	}
	return object{}, nil
}

// permissions is a request's optional permission bits (0 to 0o7777) as a
// file mode, or the default when absent.
func permissions(r *request, fallback fs.FileMode) (fs.FileMode, error) {
	if r.Permissions == nil {
		return fallback, nil
	}
	bits := *r.Permissions
	if bits < 0 || bits > 0o7777 {
		return 0, newError(kindInvalid, "permissions must be an integer from 0 to 0o7777")
	}
	mode := fs.FileMode(bits & 0o777)
	if bits&0o4000 != 0 {
		mode |= fs.ModeSetuid
	}
	if bits&0o2000 != 0 {
		mode |= fs.ModeSetgid
	}
	if bits&0o1000 != 0 {
		mode |= fs.ModeSticky
	}
	return mode, nil
}

// permissionBits is a file mode's POSIX permission bits (0o7777).
func permissionBits(mode fs.FileMode) int64 {
	bits := int64(mode.Perm())
	if mode&fs.ModeSetuid != 0 {
		bits |= 0o4000
	}
	if mode&fs.ModeSetgid != 0 {
		bits |= 0o2000
	}
	if mode&fs.ModeSticky != 0 {
		bits |= 0o1000
	}
	return bits
}

func writeExclusive(file string, data []byte, mode fs.FileMode) error {
	out, err := os.OpenFile(file, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := out.Write(data); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func entryKind(mode fs.FileMode) string {
	switch {
	case mode&fs.ModeSymlink != 0:
		return "symlink"
	case mode.IsDir():
		return "directory"
	case mode.IsRegular():
		return "file"
	}
	return "other"
}

func (e *Effects) list(r *request) (object, error) {
	directory, err := absolute(r.Path)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, err
	}
	listed := make([]object, 0, len(entries))
	for _, entry := range entries {
		listed = append(listed, object{"name": entry.Name(), "kind": entryKind(entry.Type())})
	}
	return object{"entries": listed}, nil
}

func (e *Effects) stat(r *request) (object, error) {
	file, err := absolute(r.Path)
	if err != nil {
		return nil, err
	}
	var info fs.FileInfo
	if r.Follow {
		info, err = os.Stat(file)
	} else {
		info, err = os.Lstat(file)
	}
	if err != nil {
		return nil, err
	}
	// Whole milliseconds since the epoch, rounded down as Math.floor does.
	nanoseconds := info.ModTime().UnixNano()
	milliseconds := nanoseconds / 1e6
	if nanoseconds%1e6 < 0 {
		milliseconds--
	}
	return object{"kind": entryKind(info.Mode()), "size": info.Size(), "modifiedMs": milliseconds, "permissions": permissionBits(info.Mode())}, nil
}

func (e *Effects) remove(r *request) (object, error) {
	file, err := absolute(r.Path)
	if err != nil {
		return nil, err
	}
	info, err := os.Lstat(file)
	if err != nil {
		return nil, err
	}
	switch {
	case info.IsDir() && r.Recursive:
		err = os.RemoveAll(file)
	case info.IsDir():
		err = syscall.Rmdir(file)
	default:
		err = syscall.Unlink(file)
	}
	if err != nil {
		return nil, &fs.PathError{Op: "remove", Path: file, Err: err}
	}
	return object{}, nil
}

// rename is rename(2): os.Rename refuses an existing directory as the new
// name, which rename(2) replaces when it is empty, so syscall.Rename is
// called directly. Across file systems it fails (EXDEV, failed).
func (e *Effects) rename(r *request) (object, error) {
	from, err := absolute(r.From)
	if err != nil {
		return nil, err
	}
	to, err := absolute(r.To)
	if err != nil {
		return nil, err
	}
	if err := syscall.Rename(from, to); err != nil {
		return nil, &os.LinkError{Op: "rename", Old: from, New: to, Err: err}
	}
	return object{}, nil
}

// mkdirs succeeds on an existing directory and refuses any other existing
// file with already-exists. Each directory it creates gets the request's
// permission bits (0777 without), less the umask; an existing one keeps
// its own.
func (e *Effects) mkdirs(r *request) (object, error) {
	directory, err := absolute(r.Path)
	if err != nil {
		return nil, err
	}
	bits, err := permissions(r, 0o777)
	if err != nil {
		return nil, err
	}
	if info, err := os.Stat(directory); err == nil && !info.IsDir() {
		return nil, newError(kindAlreadyExists, "not a directory: %s", directory)
	}
	if err := os.MkdirAll(directory, bits); err != nil {
		return nil, err
	}
	return object{}, nil
}
