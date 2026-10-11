// User-owned LawSpec adapter.
// Native C# adapters exercise the checked .NET scalar bridge.
// ref:DEC-acceptance-with-mutants
namespace Example;

using System.Numerics;
using System.Text;
using LawSpec;

public static class ScalarAdapters
{
    public static Rune EchoChar(Rune value) => value;

    public static int EchoCodePoint(int value) => value;

    public static char EchoCodeUnit(char value) => value;

    public static byte[] EchoBytes(byte[] value) => value;

    public static Complex64 EchoComplex(Complex64 value) => value;

    public static BigInteger Successor(sbyte value) => new BigInteger(value) + 1;

    public static sbyte Narrow(sbyte value) => value;

    public static ExactDecimal AddDecimal(ExactDecimal left, ExactDecimal right) => left + right;

    public static bool SameSymbol(Symbol left, Symbol right) => left.Equals(right);

    public static string EchoRaw(string value) => value;

    public static Optional<Nullable<sbyte>> EchoPresence(Optional<Nullable<sbyte>> value) => value;

    public static void Finish() { }

    public static ulong PreserveBig(ulong value) => value;

    public static long MachineEcho(long value) => value;
}
