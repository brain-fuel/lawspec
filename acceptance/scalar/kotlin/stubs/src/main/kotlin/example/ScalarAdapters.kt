// User-owned LawSpec adapter.
package example

import lawspec.runtime.LawSpecRuntime

object ScalarAdapters {
    // echoChar :: (Char -> Char) — scalar_adapters.lawspec:2
    fun echoChar(char1: kotlin.String): kotlin.String = TODO("echoChar")

    // echoCodePoint :: (CodePoint -> CodePoint) — scalar_adapters.lawspec:3
    fun echoCodePoint(codePoint1: kotlin.Int): kotlin.Int = TODO("echoCodePoint")

    // echoCodeUnit :: (CodeUnit16 -> CodeUnit16) — scalar_adapters.lawspec:4
    fun echoCodeUnit(codeUnit16_1: kotlin.Char): kotlin.Char = TODO("echoCodeUnit")

    // echoBytes :: (Bytes -> Bytes) — scalar_adapters.lawspec:5
    fun echoBytes(bytes1: kotlin.ByteArray): kotlin.ByteArray = TODO("echoBytes")

    // echoComplex :: (Complex64 -> Complex64) — scalar_adapters.lawspec:6
    fun echoComplex(
        complex64_1: lawspec.runtime.LawSpecRuntime.Complex
    ): lawspec.runtime.LawSpecRuntime.Complex = TODO("echoComplex")

    // successor :: (Int8 -> Integer) — scalar_adapters.lawspec:7
    fun successor(int8_1: kotlin.Byte): Number = TODO("successor")

    // narrow :: (Int8 -> Int8) — scalar_adapters.lawspec:8
    fun narrow(int8_1: kotlin.Byte): kotlin.Byte = TODO("narrow")

    // addDecimal :: (Decimal -> (Decimal -> Decimal)) — scalar_adapters.lawspec:9
    fun addDecimal(
        decimal1: java.math.BigDecimal,
        decimal2: java.math.BigDecimal,
    ): java.math.BigDecimal = TODO("addDecimal")

    // sameSymbol :: (Symbol -> (Symbol -> Bool)) — scalar_adapters.lawspec:10
    fun sameSymbol(
        symbol1: lawspec.runtime.LawSpecKotlin.Symbol,
        symbol2: lawspec.runtime.LawSpecKotlin.Symbol,
    ): kotlin.Boolean = TODO("sameSymbol")

    // echoRaw :: (Utf16Text -> Utf16Text) — scalar_adapters.lawspec:11
    fun echoRaw(utf16Text1: kotlin.String): kotlin.String = TODO("echoRaw")

    // echoPresence :: (Optional (Nullable (Int8)) -> Optional (Nullable (Int8))) —
    // scalar_adapters.lawspec:12
    fun echoPresence(
        optional1:
            lawspec.runtime.LawSpecKotlin.Optional<
                lawspec.runtime.LawSpecKotlin.Nullable<kotlin.Byte>
            >
    ): lawspec.runtime.LawSpecKotlin.Optional<lawspec.runtime.LawSpecKotlin.Nullable<kotlin.Byte>> =
        TODO("echoPresence")

    // finish :: (Unit -> Unit) — scalar_adapters.lawspec:13
    fun finish(unit1: kotlin.Unit): kotlin.Unit = TODO("finish")

    // preserveBig :: (UInt64 -> UInt64) — scalar_adapters.lawspec:14
    fun preserveBig(uint64_1: java.math.BigInteger): java.math.BigInteger = TODO("preserveBig")

    // machineEcho :: (IntSize -> IntSize) — scalar_adapters.lawspec:15
    fun machineEcho(intSize1: java.math.BigInteger): java.math.BigInteger = TODO("machineEcho")
}
