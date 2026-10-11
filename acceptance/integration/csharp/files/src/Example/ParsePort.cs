// User-owned LawSpec adapter.
namespace Example;

using System;
using System.Globalization;

public static class ParsePort
{
    public static bool ValidPort(int x) => x >= 1 && x <= 65535;
    public static string Render(int x) => ValidPort(x) ? x.ToString(CultureInfo.InvariantCulture) : throw new ArgumentException("invalid port");
    public static int Parse(string x) => int.Parse(x, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
}
