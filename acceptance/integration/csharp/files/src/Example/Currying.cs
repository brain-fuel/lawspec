// User-owned LawSpec adapter.
namespace Example;

using System.Numerics;

public static class Currying
{
    public static BigInteger SumFour(BigInteger a, BigInteger b, BigInteger c, BigInteger d) => a + b + c + d;
    public static string Format(string prefix, bool enabled, int port, string suffix) => prefix + (enabled ? port.ToString() : "") + suffix;
    public static string ReferenceFormat(string prefix, bool enabled, int port, string suffix) => string.Join("", prefix, enabled ? $"{port}" : "", suffix);
    public static string Trim(string x) => x.Trim();
}
