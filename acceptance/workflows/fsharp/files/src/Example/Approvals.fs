// User-owned LawSpec adapter: the approve workflow under the real clock.
// ref:DEC-acceptance-with-mutants
module Example.Approvals

open System.Diagnostics
open System.Threading.Tasks
open LawSpec
open LawSpec.Data
open LawSpec.Runtime

// Approves an order: whether it took less than 550ms.
let approvedQuickly (number: int64) : Task<bool> =
    task {
        let started = Stopwatch.StartNew()
        Workflow.withReal 0I (fun _ -> LawSpec.Definitions.Example.Workflows.approve { Number = number }) |> ignore
        return started.ElapsedMilliseconds < 550L
    }

// Approves an order: the messages of its failures, as reported.
let approvalErrors (number: int64) : Task<string list> =
    task {
        Example.Workflows.finished.Clear()
        let result = Workflow.withReal 0I (fun _ -> LawSpec.Definitions.Example.Workflows.approve { Number = number })
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
