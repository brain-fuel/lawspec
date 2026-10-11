// User-owned LawSpec adapter: the workflow runtime under test.
// ref:DEC-acceptance-with-mutants
namespace Example;

using System.Diagnostics;
using System.Linq;
using System.Numerics;
using System.Threading.Tasks;
using Microsoft.FSharp.Collections;
using Microsoft.FSharp.Core;
using LawSpec;
using LawSpec.CSharp;
using LawSpec.Data;
using LawSpec.Runtime;
using Value = LawSpec.Runtime.Value;

public static class Resilience
{
    public static BigInteger RuntimeExponentialDelay(BigInteger delay, BigInteger factor, BigInteger attempt) =>
        Policy.RetryDelay(Policy.Exponential((long)delay, (long)factor, Fn.None<long>()), (long)attempt);

    public static BigInteger RuntimeLinearDelay(BigInteger delay, BigInteger step, BigInteger attempt) =>
        Policy.RetryDelay(Policy.Linear((long)delay, (long)step), (long)attempt);

    public static BigInteger RuntimeFibonacciDelay(BigInteger delay, BigInteger attempt) =>
        Policy.RetryDelay(Policy.Fibonacci((long)delay), (long)attempt);

    public static FSharpList<ulong> SplitMix(ulong seed, int count)
    {
        var state = LawSpec.Runtime.Random.SeedOf(seed);
        return Fn.ListOf(Enumerable.Range(0, count).Select(_ =>
        {
            var drawn = LawSpec.Runtime.Random.Next(state);
            state = drawn.Item2;
            return drawn.Item1;
        }).ToList());
    }

    public static BigInteger FullJitter(ulong seed, BigInteger delay) =>
        Policy.Jittered(Policy.Jitter.FullJitter, (long)delay, 0L, 0L, LawSpec.Runtime.Random.SeedOf(seed)).Item1;

    private static FSharpList<BigInteger> Waits(int attempts, bool accepts) =>
        Workflow.WithVirtual(BigInteger.Zero, Fn.F1((Workflow.Runtime runtime) =>
        {
            var condition = Fn.F1((Value _) => V.Bool(accepts));
            var retry = Policy.Retry(Policy.Exponential(100000L, 2L, Fn.None<long>()), attempts, Policy.Jitter.NoJitter, Fn.Some(condition));
            var stage = Policy.Stage("stage", "stage", Fn.Some(retry), Fn.None<long>(), FSharpList<Policy.Gate>.Empty,
                Fn.None<long>(), Fn.None<FSharpFunc<Value, Value>>(), false, Fn.None<System.Tuple<long, long>>());
            Workflow.RunStage(LawSpec.Generated.Program.Schema, stage,
                Fn.F0(() => V.Data("Either::Left", Fn.List(V.Int(BigInteger.Zero)))), V.Unit);
            return Fn.ListOf(Workflow.Trace(runtime).Where(e => e.Kind == "sleep").Select(e => new BigInteger(e.Number)));
        }));

    public static FSharpList<BigInteger> RetriedWaits(int attempts) => Waits(attempts, true);

    public static FSharpList<BigInteger> RejectedWaits(int attempts) => Waits(attempts, false);

    /// <summary>Calls the generated workflow at each time under one runtime.</summary>
    public static FSharpList<bool> LimitedAt(FSharpList<BigInteger> times) =>
        Workflow.WithVirtual(BigInteger.Zero, Fn.F1((Workflow.Runtime runtime) =>
            Fn.ListOf(times.Select(time =>
            {
                Workflow.SetTime(runtime, (long)time);
                return LawSpec.Definitions.ExampleLimits.Limited(new Ticket(0L)).IsRight;
            }).ToList())));

    /// <summary>Books a ticket under a fresh runtime: the stages whose undos ran.</summary>
    public static FSharpList<string> CompensationsFor(long number) =>
        Workflow.WithVirtual(BigInteger.Zero, Fn.F1((Workflow.Runtime runtime) =>
        {
            LawSpec.Definitions.ExampleLimits.Book(new Ticket(number));
            return Fn.ListOf(Workflow.Trace(runtime).Where(e => e.Kind == "compensate").Select(e => e.Stage));
        }));

    // Quotes a ticket under a runtime with the real clock: whether it timed out.
    public static Task<bool> QuoteTimedOut(long number) => Task.Run(() =>
        Workflow.WithReal(BigInteger.Zero, Fn.F1((Workflow.Runtime _) =>
            LawSpec.Definitions.ExampleLimits.Quoted(new Ticket(number)) is Either<QuotedError, Ticket>.Left { left: var error }
            && error.IsQuotedTimedOut)));

    // Quotes a ticket under a runtime with the real clock: whether it succeeded
    // within 400ms, for ticket -2 through a hedged attempt.
    public static Task<bool> QuoteHedged(long number) => Task.Run(() =>
    {
        Limits.ResetQuotes();
        return Workflow.WithReal(BigInteger.Zero, Fn.F1((Workflow.Runtime runtime) =>
        {
            var started = Stopwatch.StartNew();
            var result = LawSpec.Definitions.ExampleLimits.Hedged(new Ticket(number));
            var quick = started.ElapsedMilliseconds < 400L;
            var hedged = Workflow.Trace(runtime).Any(e => e.Kind == "hedge");
            return result.IsRight && quick && (number != -2L || hedged);
        }));
    });
}
