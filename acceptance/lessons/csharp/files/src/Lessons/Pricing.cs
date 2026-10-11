// User-owned LawSpec adapter.
namespace Lessons;

public static class Pricing
{
    public static long PriceInCents(int value0) => value0 * (value0 >= 10 ? 225L : 250L);
}
