// User-owned LawSpec adapter.
package example

object AtoiCodec {
  // (Int32 -> Text)
  def itoa(value0: scala.Int): java.lang.String = throw NotImplementedError("itoa")

  // (Text -> Int32)
  def atoi(value0: java.lang.String): scala.Int = throw NotImplementedError("atoi")
}
