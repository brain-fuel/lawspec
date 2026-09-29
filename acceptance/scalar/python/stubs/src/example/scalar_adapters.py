# User-owned LawSpec adapter.
import lawspec_runtime as ls


# LawSpec argument 0: Char
# LawSpec result: Char
def echoChar(value0: str) -> str:
    raise NotImplementedError("echoChar")


# LawSpec argument 0: CodePoint
# LawSpec result: CodePoint
def echoCodePoint(value0: int) -> int:
    raise NotImplementedError("echoCodePoint")


# LawSpec argument 0: CodeUnit16
# LawSpec result: CodeUnit16
def echoCodeUnit(value0: int) -> int:
    raise NotImplementedError("echoCodeUnit")


# LawSpec argument 0: Bytes
# LawSpec result: Bytes
def echoBytes(value0: bytes) -> bytes:
    raise NotImplementedError("echoBytes")


# LawSpec argument 0: Complex64
# LawSpec result: Complex64
def echoComplex(value0: complex) -> complex:
    raise NotImplementedError("echoComplex")


# LawSpec argument 0: Int8
# LawSpec result: BigInt
def successor(value0: int) -> int:
    raise NotImplementedError("successor")


# LawSpec argument 0: Int8
# LawSpec result: Int8
def narrow(value0: int) -> int:
    raise NotImplementedError("narrow")


# LawSpec argument 0: Decimal
# LawSpec argument 1: Decimal
# LawSpec result: Decimal
def addDecimal(value0: ls.Decimal, value1: ls.Decimal) -> ls.Decimal:
    raise NotImplementedError("addDecimal")


# LawSpec argument 0: Symbol
# LawSpec argument 1: Symbol
# LawSpec result: Bool
def sameSymbol(value0: ls.Symbol, value1: ls.Symbol) -> bool:
    raise NotImplementedError("sameSymbol")


# LawSpec argument 0: Utf16Text
# LawSpec result: Utf16Text
def echoRaw(value0: ls.Raw) -> ls.Raw:
    raise NotImplementedError("echoRaw")


# LawSpec argument 0: Optional (Nullable (Int8))
# LawSpec result: Optional (Nullable (Int8))
def echoPresence(value0: ls.Presence) -> ls.Presence:
    raise NotImplementedError("echoPresence")


# LawSpec argument 0: Unit
# LawSpec result: Unit
def finish(value0: ls.Absence) -> None:
    raise NotImplementedError("finish")


# LawSpec argument 0: UInt64
# LawSpec result: UInt64
def preserveBig(value0: int) -> int:
    raise NotImplementedError("preserveBig")


# LawSpec argument 0: IntSize
# LawSpec result: IntSize
def machineEcho(value0: int) -> int:
    raise NotImplementedError("machineEcho")
