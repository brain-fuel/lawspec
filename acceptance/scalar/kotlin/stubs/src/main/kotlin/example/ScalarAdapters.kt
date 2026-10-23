// User-owned LawSpec adapter.
package example

import lawspec.runtime.LawSpecRuntime

object ScalarAdapters {
    // echoChar :: (Char -> Char) — scalar_adapters.lawspec:2
    fun echoChar(value0: kotlin.String): kotlin.String = TODO("echoChar")

    // echoCodePoint :: (CodePoint -> CodePoint) — scalar_adapters.lawspec:3
    fun echoCodePoint(value0: kotlin.Int): kotlin.Int = TODO("echoCodePoint")

    // echoCodeUnit :: (CodeUnit16 -> CodeUnit16) — scalar_adapters.lawspec:4
    fun echoCodeUnit(value0: kotlin.Char): kotlin.Char = TODO("echoCodeUnit")

    // echoBytes :: (Bytes -> Bytes) — scalar_adapters.lawspec:5
    fun echoBytes(value0: kotlin.ByteArray): kotlin.ByteArray = TODO("echoBytes")

    // echoComplex :: (Complex64 -> Complex64) — scalar_adapters.lawspec:6
    fun echoComplex(
        value0: lawspec.runtime.LawSpecRuntime.Complex
    ): lawspec.runtime.LawSpecRuntime.Complex = TODO("echoComplex")

    // successor :: (Int8 -> Integer) — scalar_adapters.lawspec:7
    fun successor(value0: kotlin.Byte): Number = TODO("successor")

    // narrow :: (Int8 -> Int8) — scalar_adapters.lawspec:8
    fun narrow(value0: kotlin.Byte): kotlin.Byte = TODO("narrow")

    // addDecimal :: (Decimal -> (Decimal -> Decimal)) — scalar_adapters.lawspec:9
    fun addDecimal(
        value0: java.math.BigDecimal,
        value1: java.math.BigDecimal,
    ): java.math.BigDecimal = TODO("addDecimal")

    // sameSymbol :: (Symbol -> (Symbol -> Bool)) — scalar_adapters.lawspec:10
    fun sameSymbol(
        value0: lawspec.runtime.LawSpecKotlin.Symbol,
        value1: lawspec.runtime.LawSpecKotlin.Symbol,
    ): kotlin.Boolean = TODO("sameSymbol")

    // echoRaw :: (Utf16Text -> Utf16Text) — scalar_adapters.lawspec:11
    fun echoRaw(value0: kotlin.String): kotlin.String = TODO("echoRaw")

    // echoPresence :: (Optional (Nullable (Int8)) -> Optional (Nullable (Int8))) —
    // scalar_adapters.lawspec:12
    fun echoPresence(
        value0: lawspec.runtime.LawSpecKotlin.Optional<
            lawspec.runtime.LawSpecKotlin.Nullable<kotlin.Byte>
        >
    ): lawspec.runtime.LawSpecKotlin.Optional<lawspec.runtime.LawSpecKotlin.Nullable<kotlin.Byte>> =
        TODO("echoPresence")

    // finish :: (Unit -> Unit) — scalar_adapters.lawspec:13
    fun finish(value0: kotlin.Unit): kotlin.Unit = TODO("finish")

    // preserveBig :: (UInt64 -> UInt64) — scalar_adapters.lawspec:14
    fun preserveBig(value0: java.math.BigInteger): java.math.BigInteger = TODO("preserveBig")

    // machineEcho :: (IntSize -> IntSize) — scalar_adapters.lawspec:15
    fun machineEcho(value0: java.math.BigInteger): java.math.BigInteger = TODO("machineEcho")
}
