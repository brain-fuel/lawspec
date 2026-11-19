package effects

import (
	"encoding/binary"
	"io/fs"
	"strings"
	"unsafe"

	"golang.org/x/sys/unix"
)

// storedCase gives each name of a path without symbolic links the case
// stored on disk, as the macOS C library's realpath(3) does, so that a
// case-insensitive volume reports the same path in every host. It asks
// getattrlist(2) for each component's ATTR_CMN_NAME without following
// links, which needs only search permission on the parents, as realpath
// does. A mount point keeps the name in the path: getattrlist names a
// volume's root by the volume. x/sys/unix has no getattrlist wrapper, so
// it is called through unix.Syscall6; no cgo.
func storedCase(file string) (string, error) {
	if file == "/" {
		return file, nil
	}
	var stored strings.Builder
	parentDevice, err := device("/")
	if err != nil {
		return "", err
	}
	for _, part := range strings.Split(file[1:], "/") {
		current := stored.String() + "/" + part
		name, device, err := nameAndDevice(current)
		if err != nil {
			return "", err
		}
		if device != parentDevice || name == "" {
			name = part
		}
		parentDevice = device
		stored.WriteString("/")
		stored.WriteString(name)
	}
	return stored.String(), nil
}

func device(file string) (int32, error) {
	_, device, err := nameAndDevice(file)
	return device, err
}

// nameAndDevice is getattrlist(2) with ATTR_CMN_NAME and ATTR_CMN_DEVID.
// The reply is a u32 length, an attrreference_t (the name's offset from
// itself and its length with the NUL), the dev_t, then the name.
func nameAndDevice(file string) (string, int32, error) {
	pointer, err := unix.BytePtrFromString(file)
	if err != nil {
		return "", 0, err
	}
	list := unix.Attrlist{
		Bitmapcount: unix.ATTR_BIT_MAP_COUNT,
		Commonattr:  unix.ATTR_CMN_NAME | unix.ATTR_CMN_DEVID,
	}
	buffer := make([]byte, 16+4*unix.NAME_MAX)
	_, _, errno := unix.Syscall6(
		unix.SYS_GETATTRLIST,
		uintptr(unsafe.Pointer(pointer)),
		uintptr(unsafe.Pointer(&list)),
		uintptr(unsafe.Pointer(&buffer[0])),
		uintptr(len(buffer)),
		unix.FSOPT_NOFOLLOW,
		0,
	)
	if errno != 0 {
		return "", 0, &fs.PathError{Op: "getattrlist", Path: file, Err: errno}
	}
	length := int(binary.LittleEndian.Uint32(buffer))
	offset := 4 + int(int32(binary.LittleEndian.Uint32(buffer[4:])))
	size := int(binary.LittleEndian.Uint32(buffer[8:]))
	deviceID := int32(binary.LittleEndian.Uint32(buffer[12:]))
	if length > len(buffer) || offset < 16 || size < 1 || offset+size > length {
		return "", deviceID, nil
	}
	return string(buffer[offset : offset+size-1]), deviceID, nil
}
