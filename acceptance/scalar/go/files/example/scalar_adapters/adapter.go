// User-owned LawSpec adapter.
package scalar_adapters

// EchoChar implements echoChar :: (Char -> Char).
func EchoChar(value0 rune) rune {
	return value0
}

// EchoCodePoint implements echoCodePoint :: (CodePoint -> CodePoint).
func EchoCodePoint(value0 rune) rune {
	return value0
}

// EchoCodeUnit implements echoCodeUnit :: (CodeUnit16 -> CodeUnit16).
func EchoCodeUnit(value0 uint16) uint16 {
	return value0
}

// EchoBytes implements echoBytes :: (Bytes -> Bytes).
func EchoBytes(value0 []byte) []byte {
	return value0
}

// EchoComplex implements echoComplex :: (Complex64 -> Complex64).
func EchoComplex(value0 complex64) complex64 {
	return value0
}

// Successor implements successor :: (Int8 -> BigInt).
func Successor(value0 int8) *LawSpecBigInt {
	return new(LawSpecBigInt).SetInt64(int64(value0) + 1)
}

// Narrow implements narrow :: (Int8 -> Int8).
func Narrow(value0 int8) int8 {
	return value0
}

// AddDecimal implements addDecimal :: (Decimal -> (Decimal -> Decimal)).
func AddDecimal(value0 LawSpecValue, value1 LawSpecValue) LawSpecValue {
	return lsBinary("+", value0, value1)
}

// SameSymbol implements sameSymbol :: (Symbol -> (Symbol -> Bool)).
func SameSymbol(value0 LawSpecValue, value1 LawSpecValue) bool {
	return lsEqual(value0, value1)
}

// EchoRaw implements echoRaw :: (Utf16Text -> Utf16Text).
func EchoRaw(value0 []uint16) []uint16 {
	return value0
}

// EchoPresence implements echoPresence :: (Optional (Nullable (Int8)) -> Optional (Nullable
// (Int8))).
func EchoPresence(
	value0 LawSpecOptional[LawSpecNullable[int8]],
) LawSpecOptional[LawSpecNullable[int8]] {
	return value0
}

// Finish implements finish :: (Unit -> Unit).
func Finish(value0 LawSpecValue) {
	return
}

// PreserveBig implements preserveBig :: (UInt64 -> UInt64).
func PreserveBig(value0 uint64) uint64 {
	return value0
}

// MachineEcho implements machineEcho :: (IntSize -> IntSize).
func MachineEcho(value0 int) int {
	return value0
}
