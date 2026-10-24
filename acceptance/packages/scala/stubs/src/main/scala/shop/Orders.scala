// User-owned LawSpec adapter.
package shop

object Orders {
  // settlement :: (shop.orders::type::Currency -> shop.domain::type::Currency)
  // — orders.lawspec:13
  def settlement(
      value0: lawspec.data.ShopOrdersCurrency
  ): lawspec.data.ShopDomainCurrency =
    throw NotImplementedError("settlement")

  // lineTotal :: (shop.orders::type::Line -> shop.domain::type::Money) —
  // orders.lawspec:14
  def lineTotal(value0: lawspec.data.Line): lawspec.data.Money =
    throw NotImplementedError("lineTotal")

  // cheaper :: (Int64 -> (Int64 -> Int64)) — orders.lawspec:17
  def cheaper(value0: scala.Long, value1: scala.Long): scala.Long =
    throw NotImplementedError("cheaper")

  // roundDown :: (Int64 -> Int64) — orders.lawspec:18
  def roundDown(value0: scala.Long): scala.Long =
    throw NotImplementedError("roundDown")

  // classify :: (Int64 -> shop.tax.v2x0x0.rates::type::Band) —
  // orders.lawspec:19
  def classify(value0: scala.Long): lawspec.data.ShopTaxV2x0x0RatesBand =
    throw NotImplementedError("classify")
}
