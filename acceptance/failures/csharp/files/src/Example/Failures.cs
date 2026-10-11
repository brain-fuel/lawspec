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
        if (cents == 0) return Outcome.Error<int, PaymentError>(PaymentError.NewDeclined("there is nothing to settle"));
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
