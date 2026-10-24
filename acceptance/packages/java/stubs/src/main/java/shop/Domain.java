// User-owned LawSpec adapter.

package shop;

public final class Domain
{
  // convert :: (shop.domain::type::Currency -> (shop.domain::type::Money ->
  // shop.domain::type::Money)) — examples/packages/shop-domain/src/domain.lawspec:47
  public static lawspec.data.Money convert(
      lawspec.data.ShopDomainCurrency value0, lawspec.data.Money value1)
  {
    throw new UnsupportedOperationException("convert -> shop.domain::type::Money");
  }
}
