// User-owned LawSpec adapter.
package example

import lawspec.runtime.LawSpecRuntime

object ScalarAdapters {
    // (Char -> Char)
    fun echoChar(value0: kotlin.String): kotlin.String = value0

    // (CodePoint -> CodePoint)
    fun echoCodePoint(value0: kotlin.Int): kotlin.Int = value0

    // (CodeUnit16 -> CodeUnit16)
    fun echoCodeUnit(value0: kotlin.Char): kotlin.Char = value0

    // (Bytes -> Bytes)
    fun echoBytes(value0: kotlin.ByteArray): kotlin.ByteArray = value0

    // (Complex64 -> Complex64)
    fun echoComplex(
        value0: lawspec.runtime.LawSpecRuntime.Complex,
    ): lawspec.runtime.LawSpecRuntime.Complex =
        value0

    // (Int8 -> BigInt)
    fun successor(value0: kotlin.Byte): java.math.BigInteger = java.math.BigInteger.valueOf(value0.toLong() + 1)

    // (Int8 -> Int8)
    fun narrow(value0: kotlin.Byte): kotlin.Byte = value0

    // (Decimal -> (Decimal -> Decimal))
    fun addDecimal(
        value0: java.math.BigDecimal,
        value1: java.math.BigDecimal,
    ): java.math.BigDecimal =
        value0.add(value1)

    // (Symbol -> (Symbol -> Bool))
    fun sameSymbol(
        value0: lawspec.runtime.LawSpecKotlin.Symbol,
        value1: lawspec.runtime.LawSpecKotlin.Symbol,
    ): kotlin.Boolean =
        value0 == value1

    // (Utf16Text -> Utf16Text)
    fun echoRaw(value0: kotlin.String): kotlin.String = value0

    // (Optional (Nullable (Int8)) -> Optional (Nullable (Int8)))
    fun echoPresence(
        value0: lawspec.runtime.LawSpecKotlin.Optional<
            lawspec.runtime.LawSpecKotlin.Nullable<kotlin.Byte>>,
    ): lawspec.runtime.LawSpecKotlin.Optional<lawspec.runtime.LawSpecKotlin.Nullable<kotlin.Byte>> =
        value0

    // (Unit -> Unit)
    fun finish(value0: kotlin.Unit): kotlin.Unit = Unit

    // (UInt64 -> UInt64)
    fun preserveBig(value0: java.math.BigInteger): java.math.BigInteger = value0

    // (IntSize -> IntSize)
    fun machineEcho(value0: java.math.BigInteger): java.math.BigInteger = value0
}
