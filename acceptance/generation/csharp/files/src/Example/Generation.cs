// User-owned LawSpec adapter: the portable generator under test.
// ref:DEC-portable-seeded-generation ref:DEC-acceptance-with-mutants
namespace Example;

using System.Numerics;
using Microsoft.FSharp.Collections;
using LawSpec.Runtime;

public static class Generation
{
    public static FSharpList<string> Generated(string text, ulong seed, int size, int count) =>
        Descriptors.Generated(text, new BigInteger(seed), size, count);

    public static FSharpList<string> Shrunk(string text, ulong seed, int size) =>
        Descriptors.Shrunk(text, new BigInteger(seed), size);
}
