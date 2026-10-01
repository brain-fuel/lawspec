// User-owned LawSpec adapter.
package example

object Orders {
    private fun priceOf(sku: String): Int =
        if (sku == "free") 0 else sku.codePointCount(0, sku.length) % 100

    suspend fun price(value0: String): Int = priceOf(value0)

    suspend fun stock(value0: String): Int = value0.codePointCount(0, value0.length)

    fun quote(value0: String): Int = priceOf(value0)
}
