// User-owned LawSpec adapter.
package example

object AtoiCodec {
  // itoa :: (Int32 -> Text) — atoi_codec.lawspec:3
  def itoa(int32_1: scala.Int): java.lang.String =
    throw NotImplementedError("itoa")

  // atoi :: (Text -> Int32) — atoi_codec.lawspec:4
  def atoi(text1: java.lang.String): scala.Int =
    throw NotImplementedError("atoi")
}
