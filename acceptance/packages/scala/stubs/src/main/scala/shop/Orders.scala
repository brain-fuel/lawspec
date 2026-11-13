// User-owned LawSpec adapter.
package shop

object Orders {
  // settlement :: (shop.orders::type::Currency -> shop.domain::type::Currency)
  // — orders.lawspec:13
  def settlement(
      currency1: lawspec.data.ShopOrdersCurrency
  ): lawspec.data.ShopDomainCurrency =
    throw NotImplementedError("settlement")

  // lineTotal :: (shop.orders::type::Line -> shop.domain::type::Money) —
  // orders.lawspec:14
  def lineTotal(line1: lawspec.data.Line): lawspec.data.Money =
    throw NotImplementedError("lineTotal")

  // cheaper :: (Int64 -> (Int64 -> Int64)) — orders.lawspec:17
  def cheaper(int64_1: scala.Long, int64_2: scala.Long): scala.Long =
    throw NotImplementedError("cheaper")

  // roundDown :: (Int64 -> Int64) — orders.lawspec:18
  def roundDown(int64_1: scala.Long): scala.Long =
    throw NotImplementedError("roundDown")

  // classify :: (Int64 -> shop.tax.v2x0x0.rates::type::Band) —
  // orders.lawspec:19
  def classify(int64_1: scala.Long): lawspec.data.ShopTaxV2x0x0RatesBand =
    throw NotImplementedError("classify")
}
