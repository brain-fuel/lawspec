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

    // Approves an order: whether it took less than 550ms.
    public static Task<bool> ApprovedQuickly(long number) => Task.Run(() =>
    {
        var started = Stopwatch.StartNew();
        Approve(number);
        return started.ElapsedMilliseconds < 550L;
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
