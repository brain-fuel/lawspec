// User-owned LawSpec adapter.
namespace Lessons;

using System.Globalization;

public static class Codec
{
    public static string FormatQuantity(int value0) => value0.ToString(CultureInfo.InvariantCulture);

    public static int ParseQuantity(string value0) => int.Parse(value0, CultureInfo.InvariantCulture);
}
