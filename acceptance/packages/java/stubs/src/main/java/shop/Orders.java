// User-owned LawSpec adapter.
package shop;

public final class Orders {
  // (shop.orders::type::Currency -> shop.domain::type::Currency)
  public static lawspec.data.ShopDomainCurrency settlement(lawspec.data.ShopOrdersCurrency value0) {
    throw new UnsupportedOperationException("settlement -> shop.domain::type::Currency");
  }

  // (shop.orders::type::Line -> shop.domain::type::Money)
  public static lawspec.data.Money lineTotal(lawspec.data.Line value0) {
    throw new UnsupportedOperationException("lineTotal -> shop.domain::type::Money");
  }

  // (Int64 -> (Int64 -> Int64))
  public static long cheaper(long value0, long value1) {
    throw new UnsupportedOperationException("cheaper -> Int64");
  }

  // (Int64 -> Int64)
  public static long roundDown(long value0) {
    throw new UnsupportedOperationException("roundDown -> Int64");
  }
}
