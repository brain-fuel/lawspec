// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Example;

using System.Numerics;
using LawSpec.Data;

public static class Indexed
{
    public static Vec<sbyte> Replicate(BigInteger count, sbyte item)
    {
        var result = Vec<sbyte>.VNil;
        for (var i = BigInteger.Zero; i < count; i++)
            result = Vec<sbyte>.NewVCons(new LawSpec.Data.VConsDetails<sbyte>(item, result));
        return result;
    }

    public static Vec<sbyte> Append(Vec<sbyte> front, Vec<sbyte> back) => front switch
    {
        Vec<sbyte>.VCons cons => Vec<sbyte>.NewVCons(new LawSpec.Data.VConsDetails<sbyte>(cons.value.Head, Append(cons.value.Tail, back))),
        _ => back,
    };

    public static Vec<bool> Zip(Vec<sbyte> left, Vec<bool> right) => (left, right) switch
    {
        (Vec<sbyte>.VCons l, Vec<bool>.VCons r) => Vec<bool>.NewVCons(new LawSpec.Data.VConsDetails<bool>(r.value.Head, Zip(l.value.Tail, r.value.Tail))),
        _ => Vec<bool>.VNil,
    };

    public static Vec<sbyte> Flatten(Tree<sbyte> tree)
    {
        if (tree is not Tree<sbyte>.Bin bin) return Vec<sbyte>.VNil;
        var right = Vec<sbyte>.NewVCons(new LawSpec.Data.VConsDetails<sbyte>(bin.value.Value, Flatten(bin.value.Right)));
        return Append(Flatten(bin.value.Left), right);
    }
}
