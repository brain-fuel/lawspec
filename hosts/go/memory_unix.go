//go:build unix

package lawspec

import (
	"golang.org/x/sys/unix"

	"github.com/tetratelabs/wazero/experimental"
)

// mappedMemory backs a linear memory with an anonymous mapping reserved at
// the memory's maximum size and made accessible as it grows. By default
// wazero grows a memory by appending to a Go slice, which copies it and
// leaves every old copy to Go's collector, whose goal is twice the live
// heap: over fmt --check on examples/specs that held about 350 MB of dead
// copies at the peak. A reservation never moves, so growing copies
// nothing, and the memory is outside Go's heap. This is the allocator
// go-sqlite3 gives wazero. ref:wazero-memory-allocator ref:go-sqlite3-alloc
type mappedMemory struct {
	reserved  []byte
	committed int
}

// mappedAllocator reserves address space for each linear memory; when it
// cannot, the memory is wazero's ordinary Go slice.
var mappedAllocator = experimental.MemoryAllocatorFunc(func(capacity, maximum uint64) experimental.LinearMemory {
	reserved, err := unix.Mmap(-1, 0, int(maximum), unix.PROT_NONE, unix.MAP_PRIVATE|unix.MAP_ANON)
	if err != nil {
		return &sliceMemory{buffer: make([]byte, 0, capacity), maximum: maximum}
	}
	return &mappedMemory{reserved: reserved}
})

// Reallocate makes the first size bytes accessible, or returns nil beyond
// the reservation.
func (m *mappedMemory) Reallocate(size uint64) []byte {
	if size > uint64(len(m.reserved)) {
		return nil
	}
	if end := int(size); end > m.committed {
		// The new pages are the start of whole Wasm pages, so page-aligned.
		if err := unix.Mprotect(m.reserved[m.committed:end], unix.PROT_READ|unix.PROT_WRITE); err != nil {
			return nil
		}
		m.committed = end
	}
	return m.reserved[:size:size]
}

// Free releases the reservation.
func (m *mappedMemory) Free() {
	if m.reserved != nil {
		unix.Munmap(m.reserved)
		m.reserved = nil
	}
}
