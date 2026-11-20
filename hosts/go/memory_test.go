package lawspec

import "testing"

// The core's linear memory is a reservation that grows without moving or
// losing its contents and refuses growth past its maximum, so growing never
// leaves a dead copy of the old memory for Go's collector.
// ref:REQ-go-host ref:DEC-host-effect-abi
func TestMappedAllocatorGrowsInPlace(t *testing.T) {
	const page = 64 << 10
	memory := mappedAllocator.Allocate(page, 16*page)
	defer memory.Free()
	first := memory.Reallocate(page)
	if len(first) != page {
		t.Fatalf("length %d", len(first))
	}
	first[page-1] = 7
	grown := memory.Reallocate(4 * page)
	if len(grown) != 4*page || grown[page-1] != 7 {
		t.Fatalf("grown memory lost its contents")
	}
	if _, copied := memory.(*sliceMemory); !copied && &grown[0] != &first[0] {
		t.Errorf("a mapped memory moved when it grew")
	}
	grown[4*page-1] = 1
	if memory.Reallocate(17*page) != nil {
		t.Errorf("a memory grew beyond its maximum")
	}
}
