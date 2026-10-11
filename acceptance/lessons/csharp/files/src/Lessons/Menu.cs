// User-owned LawSpec adapter.
namespace Lessons;

using LawSpec.Data;

public static class Menu
{
    public static long PriceOf(Item value0) =>
        value0.IsEspresso ? 250L : value0.IsLatte ? 350L : 300L;

    public static long Cheapest(long value0, long value1) => System.Math.Min(value0, value1);
}
