// User-owned LawSpec adapter.
package shop

object Domain {
    // convert :: (shop.domain::type::Currency -> (shop.domain::type::Money ->
    // shop.domain::type::Money)) — examples/packages/shop-domain/src/domain.lawspec:47
    fun convert(
        value0: lawspec.data.ShopDomainCurrency,
        value1: lawspec.data.Money,
    ): lawspec.data.Money = TODO("convert")
}
