// User-owned LawSpec adapters for the matchers example.
package example

object Matchers {
  private val words = "[a-z0-9]+".r

  // (List (Int32) -> List (Int32))
  def sortItems(value0: List[Int]): List[Int] =
    value0.sorted

  // (List (Text) -> List (Text))
  def uniqueTags(value0: List[String]): List[String] =
    value0.distinct

  // (Int32 -> (Int32 -> Float64))
  def average(value0: Int, value1: Int): Double = (value0.toDouble + value1.toDouble) / 2

  // (Text -> Text)
  def slug(value0: String): String =
    words.findAllIn(value0.toLowerCase).toList.mkString("-")

  // (Int32 -> example.matchers::type::Order)
  def ship(value0: Int): lawspec.data.Order = lawspec.data.Order.Shipped(lawspec.data.ShippedDetails("post", value0))
}
