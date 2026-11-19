package lawspec

// sliceMemory is a linear memory in a Go slice, grown by appending, as
// wazero's default memory is.
type sliceMemory struct {
	buffer  []byte
	maximum uint64
}

func (m *sliceMemory) Reallocate(size uint64) []byte {
	if size > m.maximum {
		return nil
	}
	if grow := int(size) - len(m.buffer); grow > 0 {
		m.buffer = append(m.buffer, make([]byte, grow)...)
	}
	return m.buffer[:size]
}

func (m *sliceMemory) Free() {
	m.buffer = nil
}
