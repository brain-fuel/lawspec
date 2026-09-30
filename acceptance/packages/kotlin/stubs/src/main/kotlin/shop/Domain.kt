// User-owned LawSpec adapter.
package shop

import lawspec.runtime.LawSpecRuntime

object Domain {
    // (shop.domain::type::Currency -> (shop.domain::type::Money -> shop.domain::type::Money))
    fun convert(
        value0: lawspec.data.ShopDomainCurrency,
        value1: lawspec.data.Money,
    ): lawspec.data.Money =
        TODO("convert")
}
