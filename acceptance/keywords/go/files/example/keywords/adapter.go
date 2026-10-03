// User-owned LawSpec adapter. Go exports names by capitalizing them, so class
// needs no escape: the adapter is Class.
package keywords

// Class doubles its input.
func Class(value0 *LawSpecBigInt) *LawSpecBigInt {
	return new(LawSpecBigInt).Add(value0, value0)
}
