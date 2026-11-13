# User-owned LawSpec adapter.
import lawspec_runtime as ls


# LawSpec argument char_1: Char
# LawSpec result: Char
def echoChar(char_1: str) -> str:
    raise NotImplementedError("echoChar")


# LawSpec argument code_point_1: CodePoint
# LawSpec result: CodePoint
def echoCodePoint(code_point_1: int) -> int:
    raise NotImplementedError("echoCodePoint")


# LawSpec argument code_unit16_1: CodeUnit16
# LawSpec result: CodeUnit16
def echoCodeUnit(code_unit16_1: int) -> int:
    raise NotImplementedError("echoCodeUnit")


# LawSpec argument bytes_1: Bytes
# LawSpec result: Bytes
def echoBytes(bytes_1: bytes) -> bytes:
    raise NotImplementedError("echoBytes")


# LawSpec argument complex64_1: Complex64
# LawSpec result: Complex64
def echoComplex(complex64_1: complex) -> complex:
    raise NotImplementedError("echoComplex")


# LawSpec argument int8_1: Int8
# LawSpec result: Integer
def successor(int8_1: int) -> int:
    raise NotImplementedError("successor")


# LawSpec argument int8_1: Int8
# LawSpec result: Int8
def narrow(int8_1: int) -> int:
    raise NotImplementedError("narrow")


# LawSpec argument decimal_1: Decimal
# LawSpec argument decimal_2: Decimal
# LawSpec result: Decimal
def addDecimal(decimal_1: ls.Decimal, decimal_2: ls.Decimal) -> ls.Decimal:
    raise NotImplementedError("addDecimal")


# LawSpec argument symbol_1: Symbol
# LawSpec argument symbol_2: Symbol
# LawSpec result: Bool
def sameSymbol(symbol_1: ls.Symbol, symbol_2: ls.Symbol) -> bool:
    raise NotImplementedError("sameSymbol")


# LawSpec argument utf16_text_1: Utf16Text
# LawSpec result: Utf16Text
def echoRaw(utf16_text_1: ls.Raw) -> ls.Raw:
    raise NotImplementedError("echoRaw")


# LawSpec argument optional_1: Optional (Nullable (Int8))
# LawSpec result: Optional (Nullable (Int8))
def echoPresence(optional_1: ls.Presence) -> ls.Presence:
    raise NotImplementedError("echoPresence")


# LawSpec argument unit_1: Unit
# LawSpec result: Unit
def finish(unit_1: ls.Absence) -> None:
    raise NotImplementedError("finish")


# LawSpec argument uint64_1: UInt64
# LawSpec result: UInt64
def preserveBig(uint64_1: int) -> int:
    raise NotImplementedError("preserveBig")


# LawSpec argument int_size_1: IntSize
# LawSpec result: IntSize
def machineEcho(int_size_1: int) -> int:
    raise NotImplementedError("machineEcho")
