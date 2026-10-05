// User-owned LawSpec adapter.
package shop

import lawspec.runtime.LawSpecRuntime

object Orders {
    // (shop.orders::type::Currency -> shop.domain::type::Currency)
    fun settlement(value0: lawspec.data.ShopOrdersCurrency): lawspec.data.ShopDomainCurrency =
        TODO("settlement")

    // (shop.orders::type::Line -> shop.domain::type::Money)
    fun lineTotal(value0: lawspec.data.Line): lawspec.data.Money = TODO("lineTotal")

    // (Int64 -> (Int64 -> Int64))
    fun cheaper(value0: kotlin.Long, value1: kotlin.Long): kotlin.Long = TODO("cheaper")

    // (Int64 -> Int64)
    fun roundDown(value0: kotlin.Long): kotlin.Long = TODO("roundDown")

    // (Int64 -> shop.tax.v2_0_0.rates::type::Band)
    fun classify(value0: kotlin.Long): lawspec.data.ShopTaxV200RatesBand = TODO("classify")
}
