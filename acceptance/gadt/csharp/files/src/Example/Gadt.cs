// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Example;

using System;
using System.Numerics;
using LawSpec.Data;
using LawSpec.Runtime;

public static class Gadt
{
    // F# unions cannot refine their type arguments per case, so a match ends
    // with a case no value of the refined type has.
    public static BigInteger EvalNumber(Expr<BigInteger> expr) => expr switch
    {
        Expr<BigInteger>.Number n => n.value,
        Expr<BigInteger>.Plus p => EvalNumber(p.value.Left) + EvalNumber(p.value.Right),
        _ => throw new ArgumentException("not an Expr<BigInteger>"),
    };

    public static bool EvalTruth(Expr<bool> expr) => expr switch
    {
        Expr<bool>.Truth t => t.value,
        Expr<bool>.Same s => EvalNumber(s.value.Left) == EvalNumber(s.value.Right),
        Expr<bool>.Negate n => !EvalTruth(n.value),
        _ => throw new ArgumentException("not an Expr<bool>"),
    };

    // Both's fields have the types its equation binds (Expr<BigInteger> and
    // Expr<bool> here); F# types them Expr<Value>, so they are retyped through
    // their portable value.
    private static Expr<T> Retype<T>(Codec<T> codec, Expr<Value> value) =>
        LawSpec.Data.Codecs.Expr(codec).ToNative.Invoke(LawSpec.Data.Codecs.Expr(Codec.Portable).FromNative.Invoke(value));

    public static Pair<BigInteger, bool> EvalPair(Expr<Pair<BigInteger, bool>> expr) => expr switch
    {
        Expr<Pair<BigInteger, bool>>.Both b =>
            new Pair<BigInteger, bool>(
                EvalNumber(Retype(Codec.BigInteger, b.value.First)),
                EvalTruth(Retype(Codec.Bool, b.value.Second))),
        _ => throw new ArgumentException("not an Expr<Pair<BigInteger, bool>>"),
    };

    public static Expr<BigInteger> Fold(Expr<BigInteger> expr) => Expr<BigInteger>.NewNumber(EvalNumber(expr));

    public static string Describe(Shown shown) => shown.witness;
}
