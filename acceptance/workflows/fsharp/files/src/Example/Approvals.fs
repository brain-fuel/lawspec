// User-owned LawSpec adapter: the approve workflow under the real clock.
// ref:DEC-acceptance-with-mutants
module Example.Approvals

open System.Diagnostics
open System.Threading.Tasks
open LawSpec
open LawSpec.Data
open LawSpec.Runtime

// Approves an order: whether two of order -1's slow checks that started
// during this call overlapped in time. Run one after the other they cannot
// overlap, however loaded the machine is.
let approvedQuickly (number: int64) : Task<bool> =
    task {
        let started = Stopwatch.GetTimestamp()
        Workflow.withReal 0I (fun _ -> LawSpec.Definitions.ExampleWorkflows.approve { Number = number }) |> ignore
        return number <> -1L || Example.Workflows.overlapped started
    }

// Approves an order: the messages of its failures, as reported.
let approvalErrors (number: int64) : Task<string list> =
    task {
        Example.Workflows.finished.Clear()
        let result = Workflow.withReal 0I (fun _ -> LawSpec.Definitions.ExampleWorkflows.approve { Number = number })
        match result with
        | Either.Left(ApproveFailures failures) ->
            return
                failures
                |> List.choose (function
                    | ApproveCheckStockFailed e -> Some e
                    | ApproveCheckCreditFailed e -> Some e
                    | _ -> None)
        | _ -> return []
    }
