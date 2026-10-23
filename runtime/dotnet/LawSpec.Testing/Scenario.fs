/// Checked scenario programs run real concurrent processes, carrying vector
/// clocks with messages and joining every child before the final checks.
/// ref:DEC-sessions-by-construction ref:DEC-stateful-models-linearizability
/// ref:DEC-portable-seeded-generation
module LawSpec.Testing.Scenario

open System
open System.Numerics
open System.Threading
open System.Threading.Tasks
open LawSpec.Runtime
open LawSpec.Runtime.Descriptors
open LawSpec.Testing.ScenarioNetwork
open LawSpec.Testing.ScenarioIo

/// A step of a scenario process.
type Act =
    | Call of command: string * bound: string option * operands: Descriptor list
    | Send of target: string * operand: Descriptor
    | Receive of source: string * variable: string
    | ReceiveOr of source: string * variable: string * handler: Act list
    | Par of branches: (int * Act list) list
    | Expect of variable: string * constant: Descriptor

/// A scenario program: its channels, mailboxes and root process; the
/// branches a crash schedule may select (identity, length); its wire forms.
type Program =
    {
        Title: string
        Channels: string list
        Mailboxes: string list
        Acts: Act list
        Branches: (int * int) list
        Wire: Descriptor list option
    }

/// How scenarios run: cases and seed for check; and for one run, the receive
/// timeout (ms), whether values cross a network, whether a process crashes
/// (or which, at which step), network faults and the network deadline (ms).
type Options =
    {
        Cases: int
        Seed: BigInteger option
        ReceiveTimeout: int
        Network: bool
        Crash: bool
        Victim: (int * int) option
        Faults: MemoryOptions -> MemoryOptions
        Deadline: int
    }

[<CompiledName("Defaults")>]
let defaults =
    {
        Cases = 30
        Seed = None
        ReceiveTimeout = 5000
        Network = false
        Crash = false
        Victim = None
        Faults = id
        Deadline = 5000
    }

/// A run's report.
type Report =
    {
        Title: string
        History: History.Event list
        Outcome: string
        Clock: Clock
        Shake: BigInteger
        Victim: (int * int) option
        Network: Stats option
        Final: Value option
        Reason: string option
    }

let private fail code detail : 'a = Fail.raiseWith code detail

let private name d =
    match d with
    | Atom a -> a
    | Quoted q -> q
    | _ -> fail "InvalidScenario" (sprintf "%A" d)

let rec private annotate (acts: Descriptor list) (next: int) (eligible: bool) : Act list * int * (int * int) list =
    match acts with
    | [] -> [], next, []
    | act :: rest ->
        let a, n1, b1 = annotateAct act next eligible
        let others, n2, b2 = annotate rest n1 eligible
        a :: others, n2, b1 @ b2

and private annotateAct (act: Descriptor) (next: int) (eligible: bool) =
    match act with
    | Forms(Atom "par" :: branches) ->
        let rec go branches next =
            match branches with
            | [] -> [], next, []
            | Forms(Atom "process" :: body) :: rest ->
                let acts, n1, b1 = annotate body (next + 1) eligible
                let others, n2, b2 = go rest n1
                (next, acts) :: others, n2, (if eligible then [ next, List.length body ] else []) @ b1 @ b2
            | d :: _ -> fail "InvalidScenario" (sprintf "%A" d)

        let bs, n, found = go branches next
        Par bs, n, found
    | Forms [ Atom "receiveor"; source; variable; Forms(Atom "process" :: body) ] ->
        let acts, n, _ = annotate body next false
        ReceiveOr(name source, name variable, acts), n, []
    | Forms(Atom "call" :: command :: bound :: operands) ->
        let bound =
            match bound with
            | Hole -> None
            | Atom "_" -> None
            | b -> Some(name b)

        Call(name command, bound, operands), next, []
    | Forms [ Atom "send"; target; operand ] -> Send(name target, operand), next, []
    | Forms [ Atom "receive"; source; variable ] -> Receive(name source, name variable), next, []
    | Forms [ Atom "expect"; variable; constant ] -> Expect(name variable, constant), next, []
    | d -> fail "InvalidScenario" (sprintf "%A" d)

/// Read a program's text. Stable identities follow source order; pars inside
/// or-else handlers are real processes too, but crash schedules skip them.
[<CompiledName("Read")>]
let read (spec: string) : Program =
    let forms = Descriptors.read spec

    let find key =
        forms
        |> List.tryPick (function
            | Forms(Atom k :: rest) when k = key -> Some rest
            | _ -> None)

    let title =
        match forms with
        | Forms(Atom "scenario" :: t :: _) :: _ -> name t
        | _ -> fail "InvalidScenario" "scenario"

    let body = defaultArg (find "process") []
    let acts, _, branches = annotate body 1 true

    {
        Title = title
        Channels = defaultArg (find "channels") [] |> List.map name
        Mailboxes = defaultArg (find "mailboxes") [] |> List.map name
        Acts = acts
        Branches = branches
        Wire = find "wire"
    }

/// The process a crash schedule stops, and before which of its steps.
[<CompiledName("Victim")>]
let victim (program: Program) (shake: BigInteger) =
    match program.Branches with
    | [] -> None
    | branches ->
        let r0 = Random.seed (shake ^^^ BigInteger 0xc3a5c85c97cb3127UL)
        let i, r1 = Random.below (BigInteger(List.length branches)) r0
        let identity, length = List.item (int i) branches
        let at, _ = Random.below (BigInteger(length + 1)) r1
        Some(identity, int at)

/// Each case's shake, and whether it runs over a network or with a crash.
[<CompiledName("Schedules")>]
let schedules (seed: BigInteger) (runs: int) =
    let mutable random = Random.seed (seed ^^^ BigInteger 0x2545f4914f6cdd1dUL)

    [
        for i in 0 .. runs - 1 ->
            let shake, next = Random.next random
            random <- next
            BigInteger shake, (i % 3 = 1, i % 3 = 2)
    ]

type private Setup =
    {
        Program: Program
        Model: Model.Model
        Context: Model.Context
        System: obj
        Hub: Hub
        History: Collections.Concurrent.ConcurrentDictionary<int64, History.Event>
        Failure: string option ref
        Tick: int64 ref
        Commands: Map<string, int>
        Shake: BigInteger
        Victim: (int * int) option
        Timeout: int
    }

type private State =
    {
        Id: string
        Values: Map<string, Value>
        Ends: Map<string, Destination>
        Clock: Clock
        Random: Random.Seed
        Crashable: bool
    }

let private value (operand: Descriptor) (values: Map<string, Value>) =
    match operand with
    | Forms [ Atom "var"; n ] -> values.[name n]
    | Forms [ Atom "int"; Number n ] -> Int n
    | Forms [ Atom "bool"; b ] -> Bool(name b = "true")
    | Forms [ Atom "text"; t ] -> Text(name t)
    | Forms [ Atom "tag"; t ] -> Data(name t, [])
    | d -> fail "InvalidScenario" (sprintf "%A" d)

let private tick (setup: Setup) =
    Interlocked.Increment(&setup.Tick.contents)

let private bump (state: State) =
    { state with
        Clock = state.Clock.Add(state.Id, defaultArg (state.Clock.TryFind state.Id) 0L + 1L)
    }

let private mergeClock (a: Clock) (b: Clock) =
    b
    |> Map.fold (fun (acc: Clock) p n -> acc.Add(p, max (defaultArg (acc.TryFind p) 0L) n)) a

let private perturb (state: State) =
    let choice, next = Random.below (BigInteger 4) state.Random

    match int choice with
    | 0 -> ()
    | 1 -> Thread.Yield() |> ignore
    | _ -> Thread.Sleep 1

    { state with Random = next }

let rec private names (acts: Act list) : string list =
    acts
    |> List.collect (function
        | Send(n, Forms [ Atom "var"; v ]) -> [ n; name v ]
        | Send(n, _) -> [ n ]
        | Receive(n, _) -> [ n ]
        | ReceiveOr(n, _, handler) -> n :: names handler
        | Par branches -> branches |> List.collect (snd >> names)
        | _ -> [])
    |> List.distinct
    |> List.sort

let rec private countSends (acts: Act list) (target: string) =
    acts
    |> List.sumBy (function
        | Send(n, _) when n = target -> 1
        | Par branches -> branches |> List.sumBy (fun (_, body) -> countSends body target)
        | _ -> 0)

let private sends (acts: Act list) (boxes: string list) =
    boxes |> List.map (fun n -> n, countSends acts n) |> Map.ofList

let rec private receives (acts: Act list) (target: string) =
    acts
    |> List.exists (function
        | Receive(n, _) -> n = target
        | Par branches -> branches |> List.exists (fun (_, body) -> receives body target)
        | _ -> false)

/// Each branch's ends: those its parent passes on, or a side of a channel the
/// branch is the first or second to use.
let private divide (branches: (int * Act list) list) (channels: string list) (ends: Map<string, Destination>) =
    let indexed = List.indexed branches

    let users =
        indexed
        |> List.fold
            (fun (acc: Map<string, int list>) (i, (_, body)) ->
                names body
                |> List.fold (fun (a: Map<string, int list>) n -> a.Add(n, defaultArg (a.TryFind n) [] @ [ i ])) acc)
            Map.empty

    let plans, rest =
        indexed
        |> List.mapFold
            (fun (remaining: Map<string, Destination>) (i, (id, body)) ->
                let mine, left =
                    names body
                    |> List.fold
                        (fun (own: Map<string, Destination>, left: Map<string, Destination>) n ->
                            match left.TryFind n with
                            | Some e -> own.Add(n, e), left.Remove n
                            | None when List.contains n channels ->
                                let side = users.[n] |> List.takeWhile (fun j -> j <> i) |> List.length
                                own.Add(n, EndOf(n, side)), left
                            | None -> own, left)
                        (Map.empty, remaining)

                (id, body, mine), left)
            ends

    plans, rest

let private destination (setup: Setup) (target: string) (state: State) =
    if List.contains target setup.Program.Mailboxes then
        MailboxOf target
    else
        state.Ends.[target]

let private give (operand: Descriptor) (state: State) =
    match operand with
    | Forms [ Atom "var"; n ] ->
        match state.Ends.TryFind(name n) with
        | Some(EndOf(c, s)) ->
            Moved(c, s),
            { state with
                Ends = state.Ends.Remove(name n)
            }
        | _ -> Plain(value operand state.Values), state
    | _ -> Plain(value operand Map.empty), state

type private Step =
    | Continue of State
    | Finish of string * State

let rec private steps (setup: Setup) (acts: Act list) (index: int) (state: State) : string * State =
    let interrupted =
        setup.Failure.Value.IsSome
        || (state.Crashable
            && (match setup.Victim with
                | Some(id, at) -> string id = state.Id && at = index
                | None -> false))

    match interrupted, acts with
    | true, _ -> "failed", state
    | false, [] -> "done", state
    | false, act :: rest ->
        match perform setup act state with
        | Continue next -> steps setup rest (index + 1) next
        | Finish(outcome, last) -> outcome, last

and private perform (setup: Setup) (act: Act) (state: State) : Step =
    match act with
    | Call(command, bound, operands) ->
        let index = setup.Commands.[command]
        let step = Model.command setup.Model index
        let args = operands |> List.map (fun o -> value o state.Values)
        let s1 = bump (perturb state)
        let called = tick setup
        let result, _ = Model.invoke setup.Model setup.Context step args setup.System
        let returned = tick setup
        let s2 = bump s1

        setup.History.[called] <-
            {
                Command = index
                Arguments = args
                Result = result
                Called = called
                Returned = returned
                Process = state.Id
                CallClock = s1.Clock
                ReturnClock = s2.Clock
            }

        Continue
            { s2 with
                Values =
                    match bound with
                    | Some b -> s2.Values.Add(b, result)
                    | None -> s2.Values
            }
    | Send(target, operand) ->
        let d = destination setup target state
        let payload, s1 = give operand state
        let s2 = bump (perturb s1)
        setup.Hub.Send(state.Id, d, payload, s2.Clock)
        Continue s2
    | Receive(source, variable) -> accept setup source variable None state
    | ReceiveOr(source, variable, handler) -> accept setup source variable (Some handler) state
    | Par branches ->
        let program = setup.Program
        let plans, ends = divide branches program.Channels state.Ends

        let children =
            [
                for id, body, mine in plans ->
                    {
                        Id = string id
                        Ends = List.ofSeq mine.Values
                        Sends = sends body program.Mailboxes
                        Receives = program.Mailboxes |> List.filter (receives body)
                    }
            ]

        setup.Hub.Fork(state.Id, children)

        let tasks =
            plans
            |> List.mapi (fun i (id, body, mine) ->
                let random =
                    Random.seed (setup.Shake ^^^ (BigInteger(i + 1) * BigInteger 0x9e3779b97f4a7c15UL))

                Task.Run(fun () -> run setup (string id) body state.Values mine state.Clock random))
            |> Array.ofList

        Task.WaitAll(tasks |> Array.map (fun t -> t :> Task))
        let outcomes = tasks |> Array.map (fun t -> t.Result)
        let clock = outcomes |> Array.fold (fun acc (_, c) -> mergeClock acc c) state.Clock

        let next =
            bump
                { state with
                    Ends = ends
                    Clock = clock
                }

        if outcomes |> Array.exists (fun (o, _) -> o = "failed") then
            Finish("failed", next)
        else
            Continue next
    | Expect(variable, constant) ->
        let actual = state.Values.[variable]
        let wanted = value constant Map.empty

        if Scalar.equal actual wanted then
            Continue state
        else
            fail "ScenarioExpectation" (sprintf "%s is %A, expected %A" variable actual wanted)

and private accept (setup: Setup) (source: string) (variable: string) (handler: Act list option) (state: State) : Step =
    let d = destination setup source state

    match setup.Hub.Receive(state.Id, d, setup.Timeout), handler with
    | SenderGone, None -> Finish("failed", state)
    | SenderGone, Some acts ->
        match d with
        | EndOf _ -> setup.Hub.Abandon(state.Id, d)
        | MailboxOf _ -> ()

        let outcome, last =
            steps
                setup
                acts
                0
                { state with
                    Ends = state.Ends.Remove source
                    Crashable = false
                }

        Finish(outcome, last)
    | Arrived(payload, sent), _ ->
        let next =
            bump
                { state with
                    Clock = mergeClock state.Clock sent
                }

        match payload with
        | Moved(c, s) ->
            Continue
                { next with
                    Ends = next.Ends.Add(variable, EndOf(c, s))
                }
        | Plain v ->
            Continue
                { next with
                    Values = next.Values.Add(variable, v)
                }

and private run
    (setup: Setup)
    (id: string)
    (acts: Act list)
    (values: Map<string, Value>)
    (ends: Map<string, Destination>)
    (clock: Clock)
    (random: Random.Seed)
    : string * Clock =
    try
        try
            if id <> "root" then
                setup.Hub.Enter id

            let state =
                {
                    Id = id
                    Values = values
                    Ends = ends
                    Clock = clock
                    Random = random
                    Crashable = true
                }

            let outcome, last = steps setup acts 0 state
            outcome, last.Clock
        with e ->
            let message =
                match e with
                | :? LawSpecException as l -> l.Message
                | _ -> e.GetType().Name + ": " + e.Message

            Interlocked.CompareExchange(&setup.Failure.contents, Some(sprintf "process %s raised %s" id message), None)
            |> ignore

            "failed", clock
    finally
        (try
            setup.Hub.Leave id
         with _ ->
             ())

/// Run a program once with a shake; its report, as a success or a failure.
[<CompiledName("Run")>]
let runOnce (model: Model.Model) (program: Program) (shake: BigInteger) (options: Options) : Result<Report, Report> =
    let failed reason =
        Error
            {
                Title = program.Title
                History = []
                Outcome = "failed"
                Clock = Map.empty
                Shake = shake
                Victim = None
                Network = None
                Final = None
                Reason = Some reason
            }

    try
        if not model.Shared then
            fail "ScenarioRequiresSharedModel" model.Name

        let chosen =
            match options.Victim with
            | Some v -> Some v
            | None -> if options.Crash then victim program shake else None

        match chosen with
        | Some(id, at) ->
            match program.Branches |> List.tryFind (fun (i, _) -> i = id) with
            | Some(_, length) when at >= 0 && at <= length -> ()
            | _ -> fail "InvalidScenarioVictim" (sprintf "%d %d" id at)
        | None -> ()

        let start =
            model.StartArguments |> List.map (fun d -> Descriptors.minimal d model.Table)

        Model.withSystem model start 0 (fun context system expected ->
            let ioOptions =
                {
                    Network = options.Network
                    Wire = program.Wire
                    Shake = shake
                    Faults = options.Faults
                    Deadline = options.Deadline
                }

            withIo program.Channels (sends program.Acts program.Mailboxes) ioOptions (fun hub ->
                let setup =
                    {
                        Program = program
                        Model = model
                        Context = context
                        System = system
                        Hub = hub
                        History = Collections.Concurrent.ConcurrentDictionary()
                        Failure = ref None
                        Tick = ref 0L
                        Commands = model.Commands |> Array.mapi (fun i c -> c.Name, i) |> Map.ofArray
                        Shake = shake
                        Victim = chosen
                        Timeout = options.ReceiveTimeout
                    }

                let outcome, clock =
                    run setup "root" program.Acts Map.empty Map.empty Map.empty (Random.seed shake)

                let events =
                    setup.History
                    |> Seq.sortBy (fun kv -> kv.Key)
                    |> Seq.map (fun kv -> kv.Value)
                    |> List.ofSeq

                let report =
                    {
                        Title = program.Title
                        History = events
                        Outcome = outcome
                        Clock = clock
                        Shake = shake
                        Victim = chosen
                        Network = hub.NetworkStats()
                        Final = None
                        Reason = None
                    }

                match setup.Failure.Value with
                | Some failure -> Error { report with Reason = Some failure }
                | None when outcome = "failed" && chosen.IsNone ->
                    Error
                        { report with
                            Reason = Some "process_failed"
                        }
                | None ->
                    let final =
                        model.Abstract
                        |> Option.map (fun a -> Model.callback a context [ Model.systemState model system ])

                    if History.consistent model context events expected final system then
                        Ok { report with Final = final }
                    else
                        Error
                            { report with
                                Reason = Some "no_consistent_order"
                                Final = final
                            }))
    with e ->
        failed (
            match e with
            | :? LawSpecException as l -> l.Message
            | _ -> e.GetType().Name + ": " + e.Message
        )

/// Run a program text once with a shake: None, or why it failed.
[<CompiledName("Execute")>]
let execute (model: Model.Model) (spec: string) (shake: BigInteger) (options: Options) =
    match runOnce model (read spec) shake options with
    | Ok _ -> None
    | Error report -> Some report

/// Check a scenario over its cases: plain, over a faulty network, and with a
/// crash, in turn; the first failure is raised with its seed and shake.
[<CompiledName("CheckWith")>]
let checkWith (options: Options) (model: Model.Model) (spec: string) =
    let program = read spec
    let (Random.Seed seed) = Model.seed options.Seed

    if options.Cases <= 0 then
        fail "ScenarioRequiresCases" ""

    schedules (BigInteger seed) options.Cases
    |> List.iteri (fun i (shake, (network, crash)) ->
        match
            runOnce
                model
                program
                shake
                { options with
                    Network = network
                    Crash = crash
                }
        with
        | Ok _ -> ()
        | Error report ->
            fail
                "ScenarioFailed"
                (sprintf
                    "%s: seed %d (LAWSPEC_SEED=%d replays it), case %d, shake %A, network %b, crash %b, victim %A: %s"
                    program.Title
                    seed
                    seed
                    i
                    shake
                    network
                    crash
                    report.Victim
                    (defaultArg report.Reason "")))

/// Check a scenario with the default options.
[<CompiledName("Check")>]
let check (model: Model.Model) (spec: string) = checkWith defaults model spec
