// User-owned LawSpec adapter.
package shop

object Domain {
  // (shop.domain::type::Currency -> (shop.domain::type::Money -> shop.domain::type::Money))
  def convert(
    value0: lawspec.data.ShopDomainCurrency,
    value1: lawspec.data.Money,
  ): lawspec.data.Money =
    throw NotImplementedError("convert")
}
