// User-owned LawSpec adapters for the tables example.
package example

object Tables {
  // (Int32 -> (Int32 -> Int32))
  def shippingCost(value0: Int, value1: Int): Int = value0 * value1 + 5 * value0

  // (Int32 -> Text)
  def label(value0: Int): String = s"parcel $value0"
}
