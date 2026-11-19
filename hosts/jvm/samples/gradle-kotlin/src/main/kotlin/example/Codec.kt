// User-owned LawSpec adapter.
package example

object Codec {
    // itoa :: (Int32 -> Text) — laws/atoi_codec.lawspec:3
    fun itoa(int32_1: kotlin.Int): kotlin.String = int32_1.toString()

    // atoi :: (Text -> Int32) — laws/atoi_codec.lawspec:4
    fun atoi(text1: kotlin.String): kotlin.Int = text1.toInt()
}
