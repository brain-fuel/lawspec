// User-owned LawSpec adapter.
package example

import lawspec.runtime.LawSpecRuntime

object ScalarAdapters {
    // (Char -> Char)
    fun echoChar(value0: kotlin.String): kotlin.String = TODO("echoChar")

    // (CodePoint -> CodePoint)
    fun echoCodePoint(value0: kotlin.Int): kotlin.Int = TODO("echoCodePoint")

    // (CodeUnit16 -> CodeUnit16)
    fun echoCodeUnit(value0: kotlin.Char): kotlin.Char = TODO("echoCodeUnit")

    // (Bytes -> Bytes)
    fun echoBytes(value0: kotlin.ByteArray): kotlin.ByteArray = TODO("echoBytes")

    // (Complex64 -> Complex64)
    fun echoComplex(
        value0: lawspec.runtime.LawSpecRuntime.Complex,
    ): lawspec.runtime.LawSpecRuntime.Complex =
        TODO("echoComplex")

    // (Int8 -> BigInt)
    fun successor(value0: kotlin.Byte): java.math.BigInteger = TODO("successor")

    // (Int8 -> Int8)
    fun narrow(value0: kotlin.Byte): kotlin.Byte = TODO("narrow")

    // (Decimal -> (Decimal -> Decimal))
    fun addDecimal(
        value0: java.math.BigDecimal,
        value1: java.math.BigDecimal,
    ): java.math.BigDecimal =
        TODO("addDecimal")

    // (Symbol -> (Symbol -> Bool))
    fun sameSymbol(
        value0: lawspec.runtime.LawSpecKotlin.Symbol,
        value1: lawspec.runtime.LawSpecKotlin.Symbol,
    ): kotlin.Boolean =
        TODO("sameSymbol")

    // (Utf16Text -> Utf16Text)
    fun echoRaw(value0: kotlin.String): kotlin.String = TODO("echoRaw")

    // (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
    fun echoPresence(
        value0: lawspec.runtime.LawSpecKotlin.Optional<
            lawspec.runtime.LawSpecKotlin.Nullable<kotlin.Byte>>,
    ): lawspec.runtime.LawSpecKotlin.Optional<lawspec.runtime.LawSpecKotlin.Nullable<kotlin.Byte>> =
        TODO("echoPresence")

    // (Unit -> Unit)
    fun finish(value0: kotlin.Unit): kotlin.Unit = TODO("finish")

    // (UInt64 -> UInt64)
    fun preserveBig(value0: java.math.BigInteger): java.math.BigInteger = TODO("preserveBig")

    // (IntSize -> IntSize)
    fun machineEcho(value0: java.math.BigInteger): java.math.BigInteger = TODO("machineEcho")
}
