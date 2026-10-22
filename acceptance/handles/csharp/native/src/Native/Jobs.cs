namespace Work;

using System.Collections.Concurrent;
using Microsoft.FSharp.Core;
using LawSpec.CSharp;

/// <summary>The application's job queue, shared between threads.</summary>
public sealed class Jobs
{
    private readonly ConcurrentQueue<int> queue = new();

    public void Submit(int job) => queue.Enqueue(job);

    public FSharpOption<int> Take() => queue.TryDequeue(out var job) ? Maybe.Of(job) : Maybe.Absent<int>();

    public int Pending() => queue.Count;
}
