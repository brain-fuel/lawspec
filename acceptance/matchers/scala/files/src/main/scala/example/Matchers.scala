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
  def ship(value0: Int): lawspec.data.Order = lawspec.data.Order.Shipped(lawspec.data.Recordaaeb2c3925832586ac7d5e3c9a9cd234d3a26f7d9d0e264664a4ae58c6f71911("post", value0))
}
