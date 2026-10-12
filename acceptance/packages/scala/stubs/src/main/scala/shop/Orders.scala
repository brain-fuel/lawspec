// User-owned LawSpec adapter.
package shop

object Orders {
  // (shop.orders::type::Currency -> shop.domain::type::Currency)
  def settlement(value0: lawspec.data.ShopOrdersCurrency): lawspec.data.ShopDomainCurrency =
    throw NotImplementedError("settlement")

  // (shop.orders::type::Line -> shop.domain::type::Money)
  def lineTotal(value0: lawspec.data.Line): lawspec.data.Money =
    throw NotImplementedError("lineTotal")

  // (Int64 -> (Int64 -> Int64))
  def cheaper(value0: scala.Long, value1: scala.Long): scala.Long =
    throw NotImplementedError("cheaper")

  // (Int64 -> Int64)
  def roundDown(value0: scala.Long): scala.Long = throw NotImplementedError("roundDown")

  // (Int64 -> shop.tax.v2x0x0.rates::type::Band)
  def classify(value0: scala.Long): lawspec.data.ShopTaxV2x0x0RatesBand =
    throw NotImplementedError("classify")
}
