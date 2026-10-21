// User-owned LawSpec adapter: the approve workflow under the real clock.
// ref:DEC-acceptance-with-mutants
namespace Example;

using System.Diagnostics;
using System.Linq;
using System.Numerics;
using System.Threading.Tasks;
using Microsoft.FSharp.Collections;
using LawSpec;
using LawSpec.CSharp;
using LawSpec.Data;
using LawSpec.Runtime;

public static class Approvals
{
    private static Either<ApproveError, Order> Approve(long number) =>
        Workflow.WithReal(BigInteger.Zero, Fn.F1((Workflow.Runtime _) => LawSpec.Definitions.ExampleWorkflows.Approve(new Order(number))));

    // Approves an order: whether two of order -1's slow checks that started
    // during this call overlapped in time. Run one after the other they cannot
    // overlap, however loaded the machine is.
    public static Task<bool> ApprovedQuickly(long number) => Task.Run(() =>
    {
        long started = Stopwatch.GetTimestamp();
        Approve(number);
        return number != -1L || Workflows.Overlapped(started);
    });

    // Approves an order: the messages of its failures, as reported.
    public static Task<FSharpList<string>> ApprovalErrors(long number) => Task.Run(() =>
    {
        Workflows.Finished.Clear();
        var result = Approve(number);
        if (result is Either<ApproveError, Order>.Left { left: ApproveError.ApproveFailures { error: var failures } })
        {
            return Fn.ListOf(failures.Select(failure => failure switch
            {
                ApproveError.ApproveCheckStockFailed f => f.error,
                ApproveError.ApproveCheckCreditFailed f => f.error,
                _ => null,
            }).Where(message => message != null));
        }
        return FSharpList<string>.Empty;
    });
}
