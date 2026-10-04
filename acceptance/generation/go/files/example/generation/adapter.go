// User-owned LawSpec adapter: the portable generator under test.
package generation

// Generated is count values generated from a descriptor and seed, rendered.
func Generated(value0 string, value1 uint64, value2 int32, value3 int32) []string {
	return LawSpecGenerated(value0, value1, int64(value2), int64(value3))
}

// Shrunk is the shrink candidates of the first value generated, rendered.
func Shrunk(value0 string, value1 uint64, value2 int32) []string {
	return LawSpecShrunk(value0, value1, int64(value2))
}
