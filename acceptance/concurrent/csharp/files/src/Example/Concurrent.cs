// User-owned LawSpec adapter: a queue, a set and a map shared between
// threads, each one of .NET's own concurrent collections.
namespace Example;

using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.FSharp.Core;
using LawSpec.CSharp;
using LawSpec.Data;

public static class Concurrent
{
    private static int ids;
    private static readonly ConcurrentDictionary<int, ConcurrentQueue<int>> queues = new();
    private static readonly ConcurrentDictionary<int, ConcurrentDictionary<int, bool>> sets = new();
    private static readonly ConcurrentDictionary<int, ConcurrentDictionary<sbyte, long>> maps = new();

    // A structure by its handle; generated tests may name one first.
    private static ConcurrentQueue<int> Queue(WorkQueue handle) => queues.GetOrAdd(handle.Id, _ => new());
    private static ConcurrentDictionary<int, bool> Set(Tags handle) => sets.GetOrAdd(handle.Id, _ => new());
    private static ConcurrentDictionary<sbyte, long> Map(Cache handle) => maps.GetOrAdd(handle.Id, _ => new());

    private static FSharpOption<T> Found<T>(bool found, T value) => found ? Maybe.Of(value) : Maybe.Nothing<T>();

    public static WorkQueue NewQueue()
    {
        var handle = new WorkQueue(Interlocked.Increment(ref ids));
        Queue(handle);
        return handle;
    }

    public static Task Offer(WorkQueue queue, int job) => Task.Run(() => Queue(queue).Enqueue(job));

    public static Task<FSharpOption<int>> Poll(WorkQueue queue) =>
        Task.Run(() =>
        {
            var q = Queue(queue);
            return Found(q.TryDequeue(out var front), front);
        });

    public static Task<long> QueueSize(WorkQueue queue) => Task.Run(() => (long)Queue(queue).Count);

    public static Tags NewTags()
    {
        var handle = new Tags(Interlocked.Increment(ref ids));
        Set(handle);
        return handle;
    }

    public static Task<bool> Tag(Tags tags, int tag) => Task.Run(() => Set(tags).TryAdd(tag, true));

    public static Task<bool> Untag(Tags tags, int tag) => Task.Run(() => Set(tags).TryRemove(tag, out _));

    public static Task<bool> Tagged(Tags tags, int tag) => Task.Run(() => Set(tags).ContainsKey(tag));

    public static Cache NewCache()
    {
        var handle = new Cache(Interlocked.Increment(ref ids));
        Map(handle);
        return handle;
    }

    public static Task<FSharpOption<long>> Store(Cache cache, sbyte key, long value) =>
        Task.Run(() =>
        {
            FSharpOption<long> old = Maybe.Nothing<long>();
            Map(cache).AddOrUpdate(key, _ => { old = Maybe.Nothing<long>(); return value; }, (_, previous) => { old = Maybe.Of(previous); return value; });
            return old;
        });

    public static Task<FSharpOption<long>> Fetch(Cache cache, sbyte key) =>
        Task.Run(() => Found(Map(cache).TryGetValue(key, out var value), value));

    public static Task<FSharpOption<long>> Evict(Cache cache, sbyte key) =>
        Task.Run(() => Found(Map(cache).TryRemove(key, out var value), value));
}
