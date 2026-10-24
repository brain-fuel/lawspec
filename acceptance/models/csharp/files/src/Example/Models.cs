// User-owned LawSpec adapter: a persistent stack and an atomic counter.
namespace Example;

using System;
using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;
using LawSpec.Data;

public static class Models
{
    private sealed class Cell
    {
        public long Value;
    }

    private static readonly ConcurrentDictionary<int, Cell> counters = new();
    private static int ids;

    public static Stack Empty() => Stack.Empty;

    public static PushFlow Push(sbyte top, Stack rest) => new(Stack.NewPush(new LawSpec.Data.PushDetails(rest, top)));

    // The flow signature guarantees a nonempty stack.
    public static PopFlow Pop(Stack stack) => stack switch
    {
        Stack.Push cell => new PopFlow(cell.value.Top, cell.value.Rest),
        _ => throw new ArgumentException("pop needs a nonempty stack"),
    };

    public static PeekFlow Peek(Stack stack) => stack switch
    {
        Stack.Push cell => new PeekFlow(cell.value.Top, stack),
        _ => throw new ArgumentException("peek needs a nonempty stack"),
    };

    public static Counter NewCounter()
    {
        var id = Interlocked.Increment(ref ids);
        counters[id] = new Cell();
        return new Counter(id);
    }

    public static Task<long> Increment(Counter counter) =>
        Task.Run(() => Interlocked.Increment(ref counters[counter.Id].Value));

    public static Task<long> Decrement(Counter counter) =>
        Task.Run(() => Interlocked.Decrement(ref counters[counter.Id].Value));

    public static Task<long> Read(Counter counter) =>
        Task.Run(() => Interlocked.Read(ref counters[counter.Id].Value));
}
