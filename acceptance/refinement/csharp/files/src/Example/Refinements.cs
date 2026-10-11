// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Example;

using System.Linq;
using System.Numerics;

public static class Refinements
{
    public static BigInteger Add(sbyte a, sbyte b) => new BigInteger(a) + b;
    public static BigInteger Successor(sbyte a) => new BigInteger(a) + 1;
    public static BigInteger Count(string text) => text.EnumerateRunes().Count();
    public static BigInteger Preserve(ulong a) => new BigInteger(a);
    public static sbyte Positive(sbyte a) => a;
    public static BigInteger AbstractEcho(BigInteger a) => a;
}
