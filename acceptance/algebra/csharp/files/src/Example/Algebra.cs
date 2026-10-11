// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Example;

using System.Numerics;

public static class Algebra
{
    public static BigInteger Add(BigInteger x, BigInteger y) => x + y;
    public static BigInteger Multiply(BigInteger x, BigInteger y) => x * y;
    public static BigInteger NegateValue(BigInteger x) => -x;
    public static BigInteger MaximumValue(BigInteger x, BigInteger y) => BigInteger.Max(x, y);
    public static BigInteger SubtractValue(BigInteger x, BigInteger y) => x - y;
    public static BigInteger DivideLeft(BigInteger x, BigInteger y) => x - y;
    public static BigInteger DivideRight(BigInteger x, BigInteger y) => x + y;
}
