// User-owned LawSpec adapter: the workflow runtime under test.
// ref:DEC-acceptance-with-mutants
module Example.Resilience

open System.Diagnostics
open System.Threading.Tasks
open LawSpec
open LawSpec.Data
open LawSpec.Runtime

let runtimeExponentialDelay (delay: bigint) (factor: bigint) (attempt: bigint) : bigint =
    bigint (Policy.retryDelay (Policy.exponential (int64 delay) (int64 factor) None) (int64 attempt))

let runtimeLinearDelay (delay: bigint) (step: bigint) (attempt: bigint) : bigint =
    bigint (Policy.retryDelay (Policy.linear (int64 delay) (int64 step)) (int64 attempt))

let runtimeFibonacciDelay (delay: bigint) (attempt: bigint) : bigint =
    bigint (Policy.retryDelay (Policy.fibonacciDelay (int64 delay)) (int64 attempt))

let splitMix (seed: uint64) (count: int) : uint64 list =
    let mutable state = Random.seed (bigint seed)
    [ for _ in 1 .. count ->
          let n, next = Random.next state
          state <- next
          n ]

let fullJitter (seed: uint64) (delay: bigint) : bigint =
    bigint (fst (Policy.jitter Policy.FullJitter (int64 delay) 0L 0L (Random.seed (bigint seed))))

let private waits (attempts: int) (accepts: bool) : bigint list =
    Workflow.withVirtual 0I (fun runtime ->
        let retry = Policy.retry (Policy.exponential 100000L 2L None) (int64 attempts) Policy.NoJitter (Some(fun _ -> Bool accepts))
        let stage = Policy.stage "stage" "stage" (Some retry) None [] None None false None
        Workflow.runStage LawSpec.Generated.Program.schema stage (fun () -> Data("Either::Left", [ Int 0I ])) Value.Unit |> ignore
        Workflow.trace runtime |> List.filter (fun e -> e.Kind = "sleep") |> List.map (fun e -> bigint e.Number))

let retriedWaits (attempts: int) : bigint list = waits attempts true

let rejectedWaits (attempts: int) : bigint list = waits attempts false

/// Calls the generated workflow at each time under one runtime.
let limitedAt (times: bigint list) : bool list =
    Workflow.withVirtual 0I (fun runtime ->
        times
        |> List.map (fun time ->
            Workflow.setTime runtime (int64 time)
            match LawSpec.Definitions.Example.Limits.limited { Number = 0L } with
            | Either.Right _ -> true
            | Either.Left _ -> false))

/// Books a ticket under a fresh runtime: the stages whose undos ran.
let compensationsFor (number: int64) : string list =
    Workflow.withVirtual 0I (fun runtime ->
        LawSpec.Definitions.Example.Limits.book { Number = number } |> ignore
        Workflow.trace runtime |> List.filter (fun e -> e.Kind = "compensate") |> List.map (fun e -> e.Stage))

// Quotes a ticket under a runtime with the real clock: whether it timed out.
let quoteTimedOut (number: int64) : Task<bool> =
    task {
        return
            Workflow.withReal 0I (fun _ ->
                match LawSpec.Definitions.Example.Limits.quoted { Number = number } with
                | Either.Left QuotedTimedOut -> true
                | _ -> false)
    }

// Quotes a ticket under a runtime with the real clock: whether it succeeded
// within 400ms, for ticket -2 through a hedged attempt.
let quoteHedged (number: int64) : Task<bool> =
    task {
        Example.Limits.resetQuotes ()
        return
            Workflow.withReal 0I (fun runtime ->
                let started = Stopwatch.StartNew()
                let result = LawSpec.Definitions.Example.Limits.hedged { Number = number }
                let quick = started.ElapsedMilliseconds < 400L
                let hedged = Workflow.trace runtime |> List.exists (fun e -> e.Kind = "hedge")
                (match result with Either.Right _ -> true | _ -> false) && quick && (number <> -2L || hedged))
    }
