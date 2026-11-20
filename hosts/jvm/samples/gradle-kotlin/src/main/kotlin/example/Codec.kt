// User-owned LawSpec adapter.
package example

/**
 * The sample's native codec: the Kotlin binding of `itoa` and `atoi`, which
 * laws/atoi_codec.lawspec declares and states a law about.
 */
object Codec {
    /**
     * The native binding of `itoa :: (Int32 -> Text)`, laws/atoi_codec.lawspec:3.
     */
    fun itoa(int32_1: kotlin.Int): kotlin.String = int32_1.toString()

    /**
     * The native binding of `atoi :: (Text -> Int32)`, laws/atoi_codec.lawspec:4.
     */
    fun atoi(text1: kotlin.String): kotlin.Int = text1.toInt()
}
