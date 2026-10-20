// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
namespace Example;

using System;
using System.Linq;
using System.Numerics;
using Microsoft.FSharp.Collections;
using LawSpec.CSharp;
using LawSpec.Data;

public static class Collections
{
    public static FSharpSet<int> Dedupe(FSharpList<int> items) => SetModule.OfSeq(items);

    public static FSharpMap<string, BigInteger> WordCounts(FSharpList<string> words) =>
        MapModule.OfSeq(words.GroupBy(word => word).Select(group => Tuple.Create(group.Key, new BigInteger(group.Count()))));

    public static Queue<sbyte> Fifo(FSharpList<sbyte> items) => new Queue<sbyte>(items);

    // A Stack's top is its last item.
    public static Stack<sbyte> Lifo(FSharpList<sbyte> items) => new Stack<sbyte>(items);

    public static Deque<sbyte> Rotate(Deque<sbyte> deque) =>
        deque.Value.IsEmpty ? deque : new Deque<sbyte>(ListModule.Append(deque.Value.Tail, Fn.List(deque.Value.Head)));

    // Lists compare by value, so they can be Set elements directly.
    public static FSharpSet<FSharpList<sbyte>> DistinctRows(FSharpList<FSharpList<sbyte>> rows) => SetModule.OfSeq(rows);
}
