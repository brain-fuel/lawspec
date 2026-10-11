// User-owned LawSpec adapter.
namespace Example;

using System.Globalization;

public static class AtoiCodec
{
    public static string Itoa(int value) => value.ToString(CultureInfo.InvariantCulture);
    public static int Atoi(string value) => int.Parse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
}
