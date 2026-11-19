//go:build !unix

package lawspec

import "github.com/tetratelabs/wazero/experimental"

// mappedAllocator is wazero's ordinary Go slice where anonymous mappings
// are not available.
var mappedAllocator = experimental.MemoryAllocatorFunc(func(capacity, maximum uint64) experimental.LinearMemory {
	return &sliceMemory{buffer: make([]byte, 0, capacity), maximum: maximum}
})
