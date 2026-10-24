// User-owned LawSpec adapter.
package shop

object Orders {
    // settlement :: (shop.orders::type::Currency -> shop.domain::type::Currency) —
    // orders.lawspec:13
    fun settlement(value0: lawspec.data.ShopOrdersCurrency): lawspec.data.ShopDomainCurrency =
        TODO("settlement")

    // lineTotal :: (shop.orders::type::Line -> shop.domain::type::Money) — orders.lawspec:14
    fun lineTotal(value0: lawspec.data.Line): lawspec.data.Money = TODO("lineTotal")

    // cheaper :: (Int64 -> (Int64 -> Int64)) — orders.lawspec:17
    fun cheaper(value0: kotlin.Long, value1: kotlin.Long): kotlin.Long = TODO("cheaper")

    // roundDown :: (Int64 -> Int64) — orders.lawspec:18
    fun roundDown(value0: kotlin.Long): kotlin.Long = TODO("roundDown")

    // classify :: (Int64 -> shop.tax.v2x0x0.rates::type::Band) — orders.lawspec:19
    fun classify(value0: kotlin.Long): lawspec.data.ShopTaxV2x0x0RatesBand = TODO("classify")
}
