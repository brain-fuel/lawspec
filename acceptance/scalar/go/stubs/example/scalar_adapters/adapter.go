// User-owned LawSpec adapter.
package scalar_adapters

// EchoChar implements echoChar :: (Char -> Char).
func EchoChar(char1 rune) rune {
	panic("echoChar")
}

// EchoCodePoint implements echoCodePoint :: (CodePoint -> CodePoint).
func EchoCodePoint(codePoint1 rune) rune {
	panic("echoCodePoint")
}

// EchoCodeUnit implements echoCodeUnit :: (CodeUnit16 -> CodeUnit16).
func EchoCodeUnit(codeUnit16_1 uint16) uint16 {
	panic("echoCodeUnit")
}

// EchoBytes implements echoBytes :: (Bytes -> Bytes).
func EchoBytes(bytes1 []byte) []byte {
	panic("echoBytes")
}

// EchoComplex implements echoComplex :: (Complex64 -> Complex64).
func EchoComplex(complex64_1 complex64) complex64 {
	panic("echoComplex")
}

// Successor implements successor :: (Int8 -> Integer).
func Successor(int8_1 int8) any {
	panic("successor")
}

// Narrow implements narrow :: (Int8 -> Int8).
func Narrow(int8_1 int8) int8 {
	panic("narrow")
}

// AddDecimal implements addDecimal :: (Decimal -> (Decimal -> Decimal)).
func AddDecimal(decimal1 LawSpecValue, decimal2 LawSpecValue) LawSpecValue {
	panic("addDecimal")
}

// SameSymbol implements sameSymbol :: (Symbol -> (Symbol -> Bool)).
func SameSymbol(symbol1 LawSpecValue, symbol2 LawSpecValue) bool {
	panic("sameSymbol")
}

// EchoRaw implements echoRaw :: (Utf16Text -> Utf16Text).
func EchoRaw(utf16Text1 []uint16) []uint16 {
	panic("echoRaw")
}

// EchoPresence implements echoPresence :: (Optional (Nullable (Int8)) -> Optional (Nullable
// (Int8))).
func EchoPresence(
	optional1 LawSpecOptional[LawSpecNullable[int8]],
) LawSpecOptional[LawSpecNullable[int8]] {
	panic("echoPresence")
}

// Finish implements finish :: (Unit -> Unit).
func Finish(unit1 LawSpecValue) {
	panic("finish")
}

// PreserveBig implements preserveBig :: (UInt64 -> UInt64).
func PreserveBig(uint64_1 uint64) uint64 {
	panic("preserveBig")
}

// MachineEcho implements machineEcho :: (IntSize -> IntSize).
func MachineEcho(intSize1 int) int {
	panic("machineEcho")
}
