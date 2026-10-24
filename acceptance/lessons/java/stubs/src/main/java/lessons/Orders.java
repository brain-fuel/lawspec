// User-owned LawSpec adapter.

package lessons;

public final class Orders
{
  // price :: (lessons.orders::type::Drink -> Int64) — 04-data.lawspec:26
  public static long price(lawspec.data.Drink value0)
  {
    throw new UnsupportedOperationException("price -> Int64");
  }
}
