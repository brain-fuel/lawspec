// User-owned LawSpec adapters for the matchers example.
package example

object Matchers {
    private val words = Regex("[a-z0-9]+")

    // (List (Int32) -> List (Int32))
    fun sortItems(
        value0: kotlin.collections.List<kotlin.Int>,
    ): kotlin.collections.List<kotlin.Int> =
        value0.sorted()

    // (List (Text) -> List (Text))
    fun uniqueTags(
        value0: kotlin.collections.List<kotlin.String>,
    ): kotlin.collections.List<kotlin.String> =
        value0.distinct()

    // (Int32 -> (Int32 -> Float64))
    fun average(value0: kotlin.Int, value1: kotlin.Int): kotlin.Double = (value0.toDouble() + value1.toDouble()) / 2

    // (Text -> Text)
    fun slug(value0: kotlin.String): kotlin.String =
        words.findAll(value0.lowercase()).map { it.value }.joinToString("-")

    // (Int32 -> example.matchers::type::Order)
    fun ship(value0: kotlin.Int): lawspec.data.Order = lawspec.data.Order.Shipped(value0, "post")
}
