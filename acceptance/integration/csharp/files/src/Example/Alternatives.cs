// User-owned LawSpec adapter.
namespace Example;

using System.Globalization;

public static class Alternatives
{
    public static string Render(int x) => x.ToString(CultureInfo.InvariantCulture);
    public static string ReferenceRender(int x) => $"{x}";
    public static int Clamp(int x) => System.Math.Max(0, x);
    public static int ReferenceClamp(int x) => x < 0 ? 0 : x;
}
