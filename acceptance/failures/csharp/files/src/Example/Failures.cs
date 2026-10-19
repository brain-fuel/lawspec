// User-owned LawSpec adapter: native adapters that fail with a Result, and
// the native Gateway handler.
// ref:DEC-acceptance-with-mutants
namespace Example;

using System.Threading.Tasks;
using Microsoft.FSharp.Core;
using LawSpec.Abilities.ExampleFailures;
using LawSpec.CSharp;
using LawSpec.Data;

public static class Failures
{
    public static FSharpResult<int, PaymentError> Refund(int cents) =>
        cents > 5000
            ? Outcome.Error<int, PaymentError>(PaymentError.NewTooLarge(5000))
            : Outcome.Ok<int, PaymentError>(cents);

    public static async Task<FSharpResult<int, PaymentError>> Settle(int cents)
    {
        await Task.Yield();
        if (cents < 0) return Outcome.Error<int, PaymentError>(PaymentError.Blocked);
        if (cents == 0) return Outcome.Error<int, PaymentError>(PaymentError.NewDeclined(new LawSpec.Data.Recordf5f10555f6c6efcfede6a1b5b3a543dda5cd98cceb0297c257aa71c41066c7c7("there is nothing to settle")));
        return Outcome.Ok<int, PaymentError>(cents);
    }

    /// <summary>The native handler of Gateway: decide.</summary>
    public static IGateway GatewayHandler() => new Gateway();

    private sealed class Gateway : IGateway
    {
        public Decision Decide(int cents) =>
            cents < 0 ? Decision.Block
            : cents % 2 == 1 ? Decision.NewDecline("an odd amount")
            : Decision.Approve;
    }
}
