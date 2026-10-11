// User-owned LawSpec adapter. class is a C# keyword, but its PascalCase name
// Class is not. ref:DEC-acceptance-with-mutants
namespace Example;

using System.Numerics;

public static class Keywords
{
    public static BigInteger Class(BigInteger value) => value << 1;
}
