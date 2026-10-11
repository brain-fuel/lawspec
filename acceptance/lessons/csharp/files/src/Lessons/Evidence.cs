// User-owned LawSpec adapter.
namespace Lessons;

public static class Evidence
{
    public static bool IsWeekend(sbyte value0) => value0 == 0 || value0 == 6;

    // Truncate toward zero: the remainder has the dividend's sign, so the
    // most negative Int64 cannot overflow.
    public static long RoundToDollars(long value0) => value0 - value0 % 100;
}
