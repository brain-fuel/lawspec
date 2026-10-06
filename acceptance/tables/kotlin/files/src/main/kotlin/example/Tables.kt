// User-owned LawSpec adapters for the tables example.
package example

object Tables {
    // (Int32 -> (Int32 -> Int32))
    fun shippingCost(value0: kotlin.Int, value1: kotlin.Int): kotlin.Int = value0 * value1 + 5 * value0

    // (Int32 -> Text)
    fun label(value0: kotlin.Int): kotlin.String = "parcel $value0"
}
