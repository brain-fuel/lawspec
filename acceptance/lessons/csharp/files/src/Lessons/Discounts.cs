// User-owned LawSpec adapter.
namespace Lessons;

public static class Discounts
{
    public static long ApplyDiscount(long value0, int value1) => value0 * (100 - value1) / 100;
}
