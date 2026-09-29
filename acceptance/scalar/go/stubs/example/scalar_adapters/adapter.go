// User-owned LawSpec adapter.
package scalar_adapters

// EchoChar implements echoChar :: (Char -> Char).
func EchoChar(value0 rune) rune {
	panic("echoChar")
}

// EchoCodePoint implements echoCodePoint :: (CodePoint -> CodePoint).
func EchoCodePoint(value0 rune) rune {
	panic("echoCodePoint")
}

// EchoCodeUnit implements echoCodeUnit :: (CodeUnit16 -> CodeUnit16).
func EchoCodeUnit(value0 uint16) uint16 {
	panic("echoCodeUnit")
}

// EchoBytes implements echoBytes :: (Bytes -> Bytes).
func EchoBytes(value0 []byte) []byte {
	panic("echoBytes")
}

// EchoComplex implements echoComplex :: (Complex64 -> Complex64).
func EchoComplex(value0 complex64) complex64 {
	panic("echoComplex")
}

// Successor implements successor :: (Int8 -> BigInt).
func Successor(value0 int8) *LawSpecBigInt {
	panic("successor")
}

// Narrow implements narrow :: (Int8 -> Int8).
func Narrow(value0 int8) int8 {
	panic("narrow")
}

// AddDecimal implements addDecimal :: (Decimal -> (Decimal -> Decimal)).
func AddDecimal(value0 LawSpecValue, value1 LawSpecValue) LawSpecValue {
	panic("addDecimal")
}

// SameSymbol implements sameSymbol :: (Symbol -> (Symbol -> Bool)).
func SameSymbol(value0 LawSpecValue, value1 LawSpecValue) bool {
	panic("sameSymbol")
}

// EchoRaw implements echoRaw :: (Utf16Text -> Utf16Text).
func EchoRaw(value0 []uint16) []uint16 {
	panic("echoRaw")
}

// EchoPresence implements echoPresence :: (Optional (Nullable (Int8)) -> Optional (Nullable
// (Int8))).
func EchoPresence(
	value0 LawSpecOptional[LawSpecNullable[int8]],
) LawSpecOptional[LawSpecNullable[int8]] {
	panic("echoPresence")
}

// Finish implements finish :: (Unit -> Unit).
func Finish(value0 LawSpecValue) {
	panic("finish")
}

// PreserveBig implements preserveBig :: (UInt64 -> UInt64).
func PreserveBig(value0 uint64) uint64 {
	panic("preserveBig")
}

// MachineEcho implements machineEcho :: (IntSize -> IntSize).
func MachineEcho(value0 int) int {
	panic("machineEcho")
}
