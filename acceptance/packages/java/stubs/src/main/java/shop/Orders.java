// User-owned LawSpec adapter.

package shop;

public final class Orders
{
  // settlement :: (shop.orders::type::Currency -> shop.domain::type::Currency) — orders.lawspec:13
  public static lawspec.data.ShopDomainCurrency settlement(lawspec.data.ShopOrdersCurrency value0)
  {
    throw new UnsupportedOperationException("settlement -> shop.domain::type::" + "Currency");
  }

  // lineTotal :: (shop.orders::type::Line -> shop.domain::type::Money) — orders.lawspec:14
  public static lawspec.data.Money lineTotal(lawspec.data.Line value0)
  {
    throw new UnsupportedOperationException("lineTotal -> shop.domain::type::" + "Money");
  }

  // cheaper :: (Int64 -> (Int64 -> Int64)) — orders.lawspec:17
  public static long cheaper(long value0, long value1)
  {
    throw new UnsupportedOperationException("cheaper -> Int64");
  }

  // roundDown :: (Int64 -> Int64) — orders.lawspec:18
  public static long roundDown(long value0)
  {
    throw new UnsupportedOperationException("roundDown -> Int64");
  }

  // classify :: (Int64 -> shop.tax.v2x0x0.rates::type::Band) — orders.lawspec:19
  public static lawspec.data.ShopTaxV2x0x0RatesBand classify(long value0)
  {
    throw new UnsupportedOperationException("classify -> shop.tax.v2x0x0.rates::" + "type::Band");
  }
}
