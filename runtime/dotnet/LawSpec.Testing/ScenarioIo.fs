/// A scenario's channels, delegated ends and mailbox send obligations have
/// one owner. A single agent transfers them atomically and never runs
/// application code. Leaving a process releases both its current and its
/// unforked work.
/// ref:DEC-sessions-by-construction
module LawSpec.Testing.ScenarioIo

open System
open System.Numerics
open System.Threading
open LawSpec.Runtime
open LawSpec.Runtime.Descriptors
open LawSpec.Testing.ScenarioNetwork

/// What a receive gives: a payload and the clock it was sent at, or that its
/// sender has gone.
type Received =
    | Arrived of Payload * Clock
    | SenderGone

/// A child process to reserve before it runs: the ends it takes, the mailbox
/// sends it may make and the mailboxes it receives from.
type Child =
    {
        Id: string
        Ends: Destination list
        Sends: Map<string, int>
        Receives: string list
    }

/// How the hub's run is carried: over a network (with the program's wire
/// forms, the run's shake, fault options and the deadline in ms) or not.
type IoOptions =
    {
        Network: bool
        Wire: Descriptor list option
        Shake: BigInteger
        Faults: MemoryOptions -> MemoryOptions
        Deadline: int
    }

type private Waiting =
    {
        Reply: Received -> unit
        Fail: string -> unit
        Ticket: int64
        Timer: Timer
    }

type private QueueState =
    {
        mutable Owner: string
        mutable Closed: bool
        Items: Collections.Generic.Queue<Payload * Clock>
        mutable Waiting: Waiting option
        mutable InFlight: int
        mutable RemoteGone: bool
        mutable Outstanding: int
    }

type private ProcessState =
    {
        mutable Entered: bool
        Parent: string option
        mutable Sends: Map<string, int>
        mutable Closed: bool
    }

type private Message =
    | Request of (unit -> unit)
    | Network of Incoming
    | Timeout of Destination * int64

exception private Invalid of string

let private require condition reason =
    if not condition then
        raise (Invalid reason)

let private describe (d: Destination) =
    match d with
    | EndOf(n, s) -> sprintf "end %s %d" n s
    | MailboxOf n -> "mailbox " + n

/// The hub of one scenario run.
[<Sealed>]
type Hub(channels: string list, mailboxes: Map<string, int>, options: IoOptions) as this =
    let queues = Collections.Generic.Dictionary<Destination, QueueState>()
    let processes = Collections.Generic.Dictionary<string, ProcessState>()
    let mutable tickets = 0L

    let fresh outstanding =
        {
            Owner = "root"
            Closed = false
            Items = Collections.Generic.Queue()
            Waiting = None
            InFlight = 0
            RemoteGone = false
            Outstanding = outstanding
        }

    do
        for name in channels do
            for side in [ 0; 1 ] do
                queues.[EndOf(name, side)] <- fresh 0

        for KeyValue(name, count) in mailboxes do
            queues.[MailboxOf name] <- fresh count

        processes.["root"] <-
            {
                Entered = true
                Parent = None
                Sends = mailboxes
                Closed = false
            }

    let agent =
        new MailboxProcessor<Message>(fun inbox ->
            let rec loop () =
                async {
                    let! message = inbox.Receive()
                    this.Handle message
                    return! loop ()
                }

            loop ())

    let network =
        if options.Network then
            Some(
                new ScenarioNetwork(
                    channels,
                    List.ofSeq mailboxes.Keys,
                    options.Wire,
                    options.Shake,
                    options.Faults,
                    options.Deadline,
                    fun incoming -> agent.Post(Network incoming)
                )
            )
        else
            None

    do agent.Start()

    member private _.Queue(d: Destination) =
        match queues.TryGetValue d with
        | true, q -> q
        | _ -> raise (Invalid("unknown_destination " + describe d))

    member private _.Process(id: string) =
        match processes.TryGetValue id with
        | true, p -> p
        | _ -> raise (Invalid("unknown_process " + id))

    member private this.OwnedProcess(id: string) =
        let p = this.Process id
        require (not p.Closed && p.Entered) ("not_process_owner " + id)
        p

    member private this.OwnedQueue(id: string, d: Destination) =
        let q = this.Queue d
        require (not q.Closed && q.Owner = id) ("not_endpoint_owner " + describe d)
        q

    member private this.Discard(payload: Payload) =
        match payload with
        | Moved(n, s) -> this.CloseQueue(EndOf(n, s))
        | Plain _ -> ()

    member private this.Arrive(d: Destination, payload: Payload, clock: Clock) =
        let q = this.Queue d

        if q.Closed then
            this.Discard payload
        else
            q.Items.Enqueue((payload, clock))
            this.Wake d

    /// Drain accepted values before reporting that a sender has gone. A moved
    /// end is owned by the queue until its recipient receives it.
    member private this.Wake(d: Destination) =
        let q = this.Queue d

        match q.Waiting with
        | None -> ()
        | Some waiting ->
            if q.Items.Count > 0 then
                let payload, clock = q.Items.Dequeue()
                q.Waiting <- None

                match payload with
                | Moved(n, s) -> (this.Queue(EndOf(n, s))).Owner <- q.Owner
                | Plain _ -> ()

                waiting.Timer.Dispose()
                waiting.Reply(Arrived(payload, clock))
            else
                let gone =
                    match d with
                    | MailboxOf _ -> q.Outstanding + q.InFlight = 0
                    | EndOf(n, s) ->
                        match network with
                        | None -> (this.Queue(EndOf(n, 1 - s))).Closed
                        | Some _ -> q.RemoteGone

                if gone then
                    q.Waiting <- None
                    waiting.Timer.Dispose()
                    waiting.Reply SenderGone

    member private this.CloseQueue(d: Destination) =
        let q = this.Queue d

        if not q.Closed then
            // Mark closed before following delegated ends, so cyclic queues end.
            q.Closed <- true

            match q.Waiting with
            | Some waiting ->
                q.Waiting <- None
                waiting.Timer.Dispose()
                waiting.Reply SenderGone
            | None -> ()

            let items = List.ofSeq q.Items
            q.Items.Clear()

            for payload, _ in items do
                this.Discard payload

            match network, d with
            | None, EndOf(n, s) -> this.Wake(EndOf(n, 1 - s))
            | None, MailboxOf _ -> ()
            | Some net, _ ->
                (try
                    net.Abandon d
                 with _ ->
                     ())

    member private this.CloseProcess(id: string) =
        let p = this.Process id

        if not p.Closed then
            let sends = p.Sends
            p.Closed <- true
            p.Sends <- Map.empty

            for KeyValue(child, c) in List.ofSeq processes do
                if c.Parent = Some id then
                    this.CloseProcess child

            for KeyValue(d, q) in List.ofSeq queues do
                if q.Owner = id || id = "root" then
                    this.CloseQueue d

            for KeyValue(name, count) in sends do
                let q = this.Queue(MailboxOf name)
                q.Outstanding <- q.Outstanding - count
                this.Wake(MailboxOf name)

    member private this.Reserve(parent: string, child: Child) =
        require (not (processes.ContainsKey child.Id)) ("duplicate_process " + child.Id)
        let p = this.Process parent

        let remaining =
            child.Sends
            |> Map.fold
                (fun (quotas: Map<string, int>) name count ->
                    let available = defaultArg (quotas.TryFind name) 0
                    require (count >= 0 && count <= available) ("send_quota " + name)
                    quotas.Add(name, available - count))
                p.Sends

        for d in child.Ends @ (child.Receives |> List.map MailboxOf) do
            let q = this.OwnedQueue(parent, d)
            require q.Waiting.IsNone ("already_receiving " + describe d)
            q.Owner <- child.Id

        p.Sends <- remaining

        processes.[child.Id] <-
            {
                Entered = false
                Parent = Some parent
                Sends = child.Sends
                Closed = false
            }

    member private this.Outcome(outcome: Outcome) =
        let unflight d =
            match d with
            | MailboxOf _ -> let q = this.Queue d in q.InFlight <- q.InFlight - 1
            | EndOf _ -> ()

        match outcome with
        | Delivered(d, payload, clock) ->
            unflight d
            this.Arrive(d, payload, clock)
        | Lost(d, payload) ->
            unflight d
            this.Discard payload
            this.Wake d
        | Gone d ->
            (this.Queue d).RemoteGone <- true
            this.Wake d

    member private this.Handle(message: Message) =
        match message with
        | Request run -> run ()
        | Network incoming ->
            match network with
            | Some net ->
                let outcomes =
                    try
                        net.Event incoming
                    with _ ->
                        []

                for o in outcomes do
                    this.Outcome o
            | None -> ()
        | Timeout(d, ticket) ->
            match queues.TryGetValue d with
            | true, q ->
                match q.Waiting with
                | Some waiting when waiting.Ticket = ticket ->
                    q.Waiting <- None
                    waiting.Timer.Dispose()
                    waiting.Fail("receive_timeout " + describe d)
                | _ -> ()
            | _ -> ()

    /// Run a request in the agent; its result, or the reason it is invalid.
    member private _.Call(request: (Result<'a, string> -> unit) -> unit) : 'a =
        let result =
            agent.PostAndReply(fun channel ->
                Request(fun () ->
                    try
                        request channel.Reply
                    with
                    | Invalid reason -> channel.Reply(Error reason)
                    | :? LawSpecException as e -> channel.Reply(Error e.Message)))

        match result with
        | Ok value -> value
        | Error reason -> Fail.raiseWith "ScenarioIo" reason

    member this.Fork(parent: string, children: Child list) =
        this.Call(fun reply ->
            this.OwnedProcess parent |> ignore
            // Reserve every child's obligations before any of them runs.
            for child in children do
                this.Reserve(parent, child)

            reply (Ok()))

    member this.Enter(id: string) =
        this.Call(fun reply ->
            let p = this.Process id
            require (not p.Closed && not p.Entered) ("cannot_enter " + id)
            p.Entered <- true
            reply (Ok()))

    member this.Leave(id: string) =
        this.Call(fun reply ->
            this.Process id |> ignore
            this.CloseProcess id
            reply (Ok()))

    member this.Abandon(id: string, d: Destination) =
        this.Call(fun reply ->
            this.OwnedProcess id |> ignore
            this.OwnedQueue(id, d) |> ignore
            this.CloseQueue d
            reply (Ok()))

    member this.Send(id: string, d: Destination, payload: Payload, clock: Clock) =
        this.Call(fun reply ->
            this.OwnedProcess id |> ignore

            match payload with
            | Moved(n, s) ->
                this.OwnedQueue(id, EndOf(n, s)) |> ignore
                require (EndOf(n, s) <> d) ("self_delegation " + describe d)
            | Plain _ -> ()

            let target =
                match d with
                | EndOf(n, s) ->
                    this.OwnedQueue(id, d) |> ignore
                    EndOf(n, 1 - s)
                | MailboxOf name ->
                    let p = this.Process id
                    let count = defaultArg (p.Sends.TryFind name) 0
                    require (count > 0) ("send_quota " + name)
                    p.Sends <- p.Sends.Add(name, count - 1)
                    let q = this.Queue d
                    q.Outstanding <- q.Outstanding - 1
                    d

            match payload with
            | Moved(n, s) -> (this.Queue(EndOf(n, s))).Owner <- "queued"
            | Plain _ -> ()

            match network, (this.Queue target).Closed with
            | _, true ->
                this.Discard payload
                reply (Ok())
            | None, false ->
                this.Arrive(target, payload, clock)
                reply (Ok())
            | Some net, false ->
                if not (net.Send(d, payload, clock, reply)) then
                    let q = this.Queue target
                    q.InFlight <- q.InFlight + 1
                else
                    reply (Ok()))

    /// Receive at a destination, within a timeout in ms.
    member this.Receive(id: string, d: Destination, timeout: int) : Received =
        this.Call(fun reply ->
            this.OwnedProcess id |> ignore
            let q = this.OwnedQueue(id, d)
            require q.Waiting.IsNone ("already_receiving " + describe d)
            require (timeout >= 0) "invalid_timeout"
            tickets <- tickets + 1L
            let ticket = tickets

            let timer =
                new Timer((fun _ -> agent.Post(Timeout(d, ticket))), null, timeout, Timeout.Infinite)

            q.Waiting <-
                Some
                    {
                        Reply = Ok >> reply
                        Fail = Error >> reply
                        Ticket = ticket
                        Timer = timer
                    }

            this.Wake d)

    member this.NetworkStats() : Stats option =
        this.Call(fun reply -> reply (Ok(network |> Option.map (fun net -> net.Stats()))))

    member this.Stop() =
        this.Call(fun reply ->
            for KeyValue(_, q) in queues do
                q.Waiting
                |> Option.iter (fun w ->
                    w.Timer.Dispose()
                    w.Fail "hub_stopped")

                q.Waiting <- None

            network |> Option.iter (fun net -> net.Close())
            reply (Ok()))

        (agent :> IDisposable).Dispose()

/// A hub for a body, stopped after it.
[<CompiledName("WithIo")>]
let withIo (channels: string list) (mailboxes: Map<string, int>) (options: IoOptions) (body: Hub -> 'a) : 'a =
    let hub = new Hub(channels, mailboxes, options)

    try
        body hub
    finally
        hub.Stop()
