// User-owned LawSpec adapter: native handlers for the shop's abilities, and
// a native adapter that fails with a Left.
package example

object Shop {
  // (Int32 -> Int32)
  def refund(
    gateway: lawspec.abilities.example.Abilities.Gateway,
    value0: scala.Int,
  ): scala.util.Either[lawspec.data.PaymentError, scala.Int] =
    if (value0 > 100000) Left(lawspec.data.PaymentError.TooLarge)
    else Right(gateway.capture(value0).cents)

  /** The native handler of Log: note. */
  class LogHandler extends lawspec.abilities.example.Shop.Log {
    private val lines = scala.collection.mutable.ListBuffer.empty[String]
    override def note(value0: java.lang.String): scala.Unit = lines += value0
  }

  /** The native handler of Store Int32: load, save. */
  class StoreInt32Handler extends lawspec.abilities.example.Shop.StoreInt32 {
    private var value = 0
    override def load(): scala.Int = value
    override def save(value0: scala.Int): scala.Unit = value = value0
  }

  /** The native handler of Store Text: load, save. */
  class StoreTextHandler extends lawspec.abilities.example.Shop.StoreText {
    private var value = ""
    override def load(): java.lang.String = value
    override def save(value0: java.lang.String): scala.Unit = value = value0
  }

  /** The native handler of Meter: reading. */
  class MeterHandler extends lawspec.abilities.example.Shop.Meter {
    override def reading(): scala.Int = 3
  }
}
