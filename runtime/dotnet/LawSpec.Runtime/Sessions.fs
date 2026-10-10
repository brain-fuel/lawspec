namespace LawSpec.Runtime

open System
open System.Threading
open System.Threading.Tasks
open System.Text

/// What a protocol step carries: a value (with its wire descriptor text, if
/// it has one), or an end of another protocol.
type SessionPart =
    | ValuePart of descriptor: string option
    | EndPart of protocol: string

/// A step of a protocol, as its first end sees it.
type SessionStep = { FirstSends: bool; Part: SessionPart }

/// A protocol to open, with the catalogue of every protocol its steps name,
/// and the network deadline (ms) of its ends.
type SessionSpec =
    { Id: string
      Protocols: Map<string, SessionStep list>
      Deadline: int }

type internal SideState =
    { mutable Generation: int64
      mutable Step: int
      mutable Closed: bool
      Queue: Collections.Generic.Queue<SessionItem>
      mutable Reader: TaskCompletionSource<Result<SessionItem, string>> option }

and internal SessionItem =
    | Item of Value
    | Delegated of SessionEnd

/// One protocol conversation: a pair of affine ends. Each step consumes an
/// end and gives the next one, so a spent end fails. An end may be sent over
/// another channel (delegation); on a network, an end that has not been used
/// moves with its state, and a local one is relayed by its node.
/// ref:DEC-sessions-by-construction ref:DEC-distribution-canonical-wire
and [<Sealed; AllowNullLiteral>] SessionChannel internal (spec: SessionSpec, network: (Node * Endpoint * int) option) =
    static let generations = ref 0L
    static let custody = Collections.Generic.Dictionary<SessionChannel, SessionChannel>(HashIdentity.Reference)
    let gate = obj ()
    let steps = spec.Protocols.[spec.Id]
    let fresh () = Interlocked.Increment generations
    let side n =
        { Generation = fresh (); Step = 0; Closed = false; Queue = Collections.Generic.Queue(); Reader = None }
    let sides = [| side 0; side 1 |]
    do
        match network with
        | Some(_, _, own) -> sides.[1 - own].Step <- List.length steps
        | None -> ()

    static member internal Fail(reason: string) : 'a = Fail.raiseWith "Session" reason

    member internal _.Gate: obj = gate
    member internal _.SideState(n: int) : SideState = sides.[n]
    member _.Spec = spec
    member _.Steps = steps
    member internal _.Network = network

    member internal this.Handle(n: int) = SessionEnd(this, n, sides.[n].Generation, sides.[n].Step)

    /// The ends of a new local channel.
    static member Open(spec: SessionSpec) =
        let channel = SessionChannel(spec, None)
        channel.Handle 0, channel.Handle 1

    member internal this.Check(e: SessionEnd) =
        if not (obj.ReferenceEquals(e.Channel, this)) then SessionChannel.Fail "invalid_end"
        let s = sides.[e.Side]
        if s.Generation <> e.Generation || s.Step <> e.Step then SessionChannel.Fail "spent_end"
        if s.Closed then SessionChannel.Fail "abandoned_end"
        s

    member internal this.Part(e: SessionEnd, sending: bool) =
        let s = this.Check e
        if s.Step >= List.length steps then SessionChannel.Fail "protocol_complete"
        let step = List.item s.Step steps
        let sends = if e.Side = 0 then step.FirstSends else not step.FirstSends
        if sends <> sending then SessionChannel.Fail "wrong_step"
        step.Part

    member internal this.Advance(n: int) =
        sides.[n].Step <- sides.[n].Step + 1
        this.Handle n

    /// A new handle of an end, spending the old one (a transfer).
    member internal this.Reissue(e: SessionEnd) =
        lock gate (fun () ->
            this.Check e |> ignore
            sides.[e.Side].Generation <- fresh ()
            this.Handle e.Side)

    member private this.Wake(n: int) : (unit -> unit) list =
        let s = sides.[n]
        match s.Reader with
        | None -> []
        | Some reader ->
            if s.Queue.Count > 0 then
                s.Reader <- None
                let item = s.Queue.Dequeue()
                [ fun () -> reader.TrySetResult(Ok item) |> ignore ]
            elif sides.[1 - n].Closed && network.IsNone then
                s.Reader <- None
                s.Closed <- true
                [ fun () -> reader.TrySetResult(Error "peer_failed") |> ignore ]
            else []

    member internal this.Enqueue(n: int, item: SessionItem) =
        let actions =
            lock gate (fun () ->
                if sides.[n].Closed then
                    (match item with Delegated e -> [ fun () -> SessionChannel.Discard e ] | Item _ -> [])
                else
                    sides.[n].Queue.Enqueue item
                    this.Wake n)
        for a in actions do a ()

    /// Wait for the next item of a side.
    member internal this.Await(n: int) : SessionItem =
        let reader =
            lock gate (fun () ->
                let r = TaskCompletionSource<Result<SessionItem, string>>(TaskCreationOptions.RunContinuationsAsynchronously)
                sides.[n].Reader <- Some r
                r)
        let actions = lock gate (fun () -> this.Wake n)
        for a in actions do a ()
        match reader.Task.Result with
        | Ok item -> item
        | Error reason -> SessionChannel.Fail reason

    /// Close a side: its queue's delegated ends are discarded, and a local
    /// peer's reader learns the peer gave up.
    member internal this.CloseSide(n: int) =
        let actions =
            lock gate (fun () ->
                let s = sides.[n]
                if s.Closed then []
                else
                    s.Closed <- true
                    let discarded = [ for item in s.Queue do match item with Delegated e -> yield e | Item _ -> () ]
                    s.Queue.Clear()
                    let reader = s.Reader
                    s.Reader <- None
                    [ yield! discarded |> List.map (fun e -> fun () -> SessionChannel.Discard e)
                      match reader with
                      | Some r -> yield fun () -> r.TrySetResult(Error "abandoned_end") |> ignore
                      | None -> ()
                      match network with
                      | Some _ -> sides.[1 - n].Closed <- true
                      | None -> yield! this.Wake(1 - n) ])
        lock custody (fun () -> custody.Remove this |> ignore)
        match network with
        | Some(_, endpoint, own) when own = n -> (try endpoint.Abandon() with _ -> ())
        | _ -> ()
        for a in actions do a ()

    /// Give up an end if it is still current (whoever holds it).
    static member internal Discard(e: SessionEnd) =
        let current =
            lock e.Channel.Gate (fun () ->
                let s = e.Channel.SideState e.Side
                s.Generation = e.Generation && not s.Closed)
        if current then e.Channel.CloseSide e.Side


    /// Queue custody is a forest: moving a channel's first end into another
    /// channel fails if it would make a cycle.
    static member internal Move(child: SessionChannel, parent: SessionChannel) =
        lock custody (fun () ->
            let rec reaches (c: SessionChannel) =
                obj.ReferenceEquals(c, child) || (match custody.TryGetValue c with | true, p -> reaches p | _ -> false)
            if reaches parent then SessionChannel.Fail "cyclic_delegation"
            custody.[child] <- parent)

    static member internal Release(child: SessionChannel) = lock custody (fun () -> custody.Remove child |> ignore)

/// An end of a channel at a step. Using it spends it.
and [<Sealed; AllowNullLiteral>] SessionEnd internal (channel: SessionChannel, side: int, generation: int64, step: int) =
    member _.Channel: SessionChannel = channel
    member _.Side: int = side
    member _.Generation: int64 = generation
    member _.Step: int = step
    override _.ToString() = sprintf "session end %d of %s at step %d" side channel.Spec.Id step

/// A task that runs a body with an end it was given; joined for its result.
[<Sealed>]
type SessionTask internal (work: Task<Value>, owned: Collections.Generic.HashSet<SessionEnd>) =
    member _.Work = work
    member internal _.Owned = owned

/// Session operations, as the generated typed ends call them.
/// ref:DEC-sessions-by-construction ref:DEC-async-native-tasks
module Sessions =
    let private fail reason : 'a = SessionChannel.Fail reason
    let private textType = Descriptors.Forms [ Descriptors.Atom "text" ]
    let private owned = AsyncLocal<Collections.Generic.HashSet<SessionEnd>>()
    let private names = ref 0L

    let private track (e: SessionEnd) =
        match owned.Value with
        | null -> ()
        | set -> lock set (fun () -> set.Add e |> ignore)
        e

    let private untrack (e: SessionEnd) =
        match owned.Value with
        | null -> ()
        | set -> lock set (fun () -> set.RemoveWhere(fun o -> obj.ReferenceEquals(o.Channel, e.Channel) && o.Side = e.Side) |> ignore)

    let private encode (part: SessionPart) (value: Value) =
        match part with
        | ValuePart(Some text) ->
            let table, d = Descriptors.fromText text
            Descriptors.encode d value table
        | ValuePart None -> fail "non_wire_payload"
        | EndPart _ -> Descriptors.encode textType value Map.empty

    let private decode (part: SessionPart) (bytes: byte[]) =
        match part with
        | ValuePart(Some text) ->
            let table, d = Descriptors.fromText text
            Descriptors.decode d bytes table
        | ValuePart None -> fail "non_wire_payload"
        | EndPart _ -> Descriptors.decode textType bytes Map.empty

    /// A name no other session end on the node has.
    [<CompiledName("FreshName")>]
    let freshName () = "session-" + string (Interlocked.Increment names)

    /// Whether every protocol a network end may carry has a wire form.
    [<CompiledName("Validate")>]
    let validate (spec: SessionSpec) =
        let rec go id (seen: string list) =
            if not (List.contains id seen) then
                let steps = spec.Protocols.[id]
                if List.isEmpty steps then fail "empty_network_protocol"
                for step in steps do
                    match step.Part with
                    | EndPart other -> go other (id :: seen)
                    | ValuePart None -> fail "non_wire_payload"
                    | ValuePart(Some text) -> Descriptors.fromText text |> ignore
        go spec.Id []

    /// A new local channel's two ends.
    [<CompiledName("Open")>]
    let openPair (spec: SessionSpec) = SessionChannel.Open spec

    /// A channel for a body; both ends that were not passed on are given up after it.
    [<CompiledName("WithPair")>]
    let withPair (spec: SessionSpec) (body: SessionEnd -> SessionEnd -> 'a) : 'a =
        let first, second = openPair spec
        try body first second
        finally
            SessionChannel.Discard first
            SessionChannel.Discard second

    /// A channel end on a node over the network, connected to a peer's
    /// address if given.
    let rec networkStart (spec: SessionSpec) (node: Node) (name: string) (side: int) (connection: string option) : SessionEnd =
        validate spec
        let endpoint = new Endpoint(node, name, spec.Deadline)
        let channel = SessionChannel(spec, Some(node, endpoint, side))
        let e = channel.Handle side
        try
            connection |> Option.iter endpoint.Connect
            track e
        with ex ->
            (try endpoint.Stop() with _ -> ())
            raise ex

    /// Listen on a node: the first end, at Address.
    [<CompiledName("Listen")>]
    let listen (node: Node) (name: string) (spec: SessionSpec) = networkStart spec node name 0 None

    /// Dial a listening end: the second end.
    [<CompiledName("Dial")>]
    let dial (node: Node) (address: string) (spec: SessionSpec) = networkStart spec node (freshName ()) 1 (Some address)

    let private endpointOf (e: SessionEnd) =
        e.Channel.Check e |> ignore
        match e.Channel.Network with
        | Some(_, endpoint, _) -> endpoint
        | None -> fail "local_end"

    /// A network end's address.
    [<CompiledName("Address")>]
    let address (e: SessionEnd) = (endpointOf e).Address

    /// Send a value; the next end.
    [<CompiledName("Send")>]
    let send (e: SessionEnd) (value: Value) : SessionEnd =
        let channel = e.Channel
        match channel.Part(e, true) with
        | EndPart _ -> fail "expected_delegation"
        | part ->
            match channel.Network with
            | Some(_, endpoint, _) ->
                let bytes = encode part value
                let next = lock channel.Gate (fun () -> channel.Check e |> ignore; channel.Advance e.Side)
                endpoint.Send bytes
                untrack e
                track next
            | None ->
                let next = lock channel.Gate (fun () -> channel.Check e |> ignore; channel.Advance e.Side)
                channel.Enqueue(1 - e.Side, Item value)
                untrack e
                track next

    let private failedPeer (channel: SessionChannel) (side: int) (reason: string) : 'a =
        channel.CloseSide side
        fail ("peer_failed " + reason)

    /// Receive a value; it and the next end.
    [<CompiledName("ReceiveValue")>]
    let receiveValue (e: SessionEnd) : Value * SessionEnd =
        let channel = e.Channel
        let part = channel.Part(e, false)
        (match part with EndPart _ -> fail "wrong_receive_kind" | _ -> ())
        let next = lock channel.Gate (fun () -> channel.Check e |> ignore; channel.Advance e.Side)
        untrack e
        track next |> ignore
        match channel.Network with
        | Some(_, endpoint, _) ->
            match endpoint.Receive(Some channel.Spec.Deadline) with
            | Ok bytes ->
                let value = try decode part bytes with _ -> failedPeer channel e.Side "invalid_payload"
                value, next
            | Error reason -> failedPeer channel e.Side reason
        | None ->
            match channel.Await e.Side with
            | Item value -> value, next
            | Delegated _ -> fail "wrong_receive_kind"

    /// Give up an end.
    [<CompiledName("Abandon")>]
    let abandon (e: SessionEnd) =
        lock e.Channel.Gate (fun () -> e.Channel.Check e |> ignore)
        untrack e
        e.Channel.CloseSide e.Side

    /// The protocol an end follows.
    [<CompiledName("Specification")>]
    let specification (e: SessionEnd) = e.Channel.Spec

    /// Move an end to another holder (a task): the old handle is spent.
    [<CompiledName("Transfer")>]
    let transfer (e: SessionEnd) =
        let moved = e.Channel.Reissue e
        untrack e
        moved

    let private unusedFirst (e: SessionEnd) (expected: string) =
        lock e.Channel.Gate (fun () -> e.Channel.Check e |> ignore)
        if e.Side <> 0 || e.Step <> 0 then fail "not_an_unused_first_end"
        if e.Channel.Spec.Id <> expected then fail "different_protocol"

    /// The address a delegated end is reached at from another node: a network
    /// end moves (its offer); a local end stays, and this node relays it.
    let rec offer (node: Node) (e: SessionEnd) (expected: string) : string =
        unusedFirst e expected
        match e.Channel.Network with
        | Some(_, endpoint, _) ->
            let address = endpoint.Offer()
            // The end now belongs to its taker: spend this handle without abandoning.
            lock e.Channel.Gate (fun () ->
                let s = e.Channel.SideState e.Side
                s.Generation <- -s.Generation
                s.Closed <- true)
            untrack e
            address
        | None -> relay node e

    and private relay (node: Node) (e: SessionEnd) : string =
        let spec = e.Channel.Spec
        validate spec
        let remote = networkStart spec node (freshName ()) 1 None
        let addressOfRemote = address remote
        let local = transfer e
        let remoteMoved = transfer remote
        let steps = spec.Protocols.[spec.Id]
        Task.Run(fun () ->
            let mutable l = local
            let mutable r = remoteMoved
            try
                for step in steps do
                    match step.FirstSends, step.Part with
                    | true, ValuePart _ ->
                        let v, r' = receiveValue r
                        r <- r'
                        l <- send l v
                    | false, ValuePart _ ->
                        let v, l' = receiveValue l
                        l <- l'
                        r <- send r v
                    | true, EndPart _ ->
                        let v, r' = receiveEnd r
                        r <- r'
                        l <- sendEnd l v
                    | false, EndPart _ ->
                        let v, l' = receiveEnd l
                        l <- l'
                        r <- sendEnd r v
            with _ ->
                SessionChannel.Discard l
                SessionChannel.Discard r)
        |> ignore
        addressOfRemote

    /// The end a delegation's address names, taken on this node.
    and take (node: Node) (address: string) (spec: SessionSpec) : SessionEnd =
        let moving = address.Contains "?take="
        let e = networkStart spec node (freshName ()) 0 (if moving then None else Some address)
        try
            if moving then (endpointOf e).Take address
            e
        with ex ->
            (try abandon e with _ -> ())
            raise ex

    /// Send an unused first end of another protocol; the next end.
    and [<CompiledName("SendEnd")>] sendEnd (e: SessionEnd) (other: SessionEnd) : SessionEnd =
        let channel = e.Channel
        let expected =
            match channel.Part(e, true) with
            | EndPart id -> id
            | _ -> fail "expected_value"
        if isNull other || other.Side <> 0 || other.Step <> 0 then fail "not_an_unused_first_end"
        if obj.ReferenceEquals(other.Channel, channel) then fail "cyclic_delegation"
        match channel.Network with
        | Some(node, endpoint, _) ->
            let addressText = offer node other expected
            let next = lock channel.Gate (fun () -> channel.Check e |> ignore; channel.Advance e.Side)
            endpoint.Send(encode (EndPart expected) (Text addressText))
            untrack e
            track next
        | None ->
            unusedFirst other expected
            SessionChannel.Move(other.Channel, channel)
            let moved = transfer other
            let next = lock channel.Gate (fun () -> channel.Check e |> ignore; channel.Advance e.Side)
            channel.Enqueue(1 - e.Side, Delegated moved)
            untrack e
            track next

    /// Receive an end; it and the next end.
    and [<CompiledName("ReceiveEnd")>] receiveEnd (e: SessionEnd) : SessionEnd * SessionEnd =
        let channel = e.Channel
        let protocol =
            match channel.Part(e, false) with
            | EndPart id -> id
            | _ -> fail "wrong_receive_kind"
        let next = lock channel.Gate (fun () -> channel.Check e |> ignore; channel.Advance e.Side)
        untrack e
        track next |> ignore
        match channel.Network with
        | Some(node, endpoint, _) ->
            match endpoint.Receive(Some channel.Spec.Deadline) with
            | Ok bytes ->
                let addressText =
                    match (try decode (EndPart protocol) bytes with _ -> failedPeer channel e.Side "invalid_payload") with
                    | Text a -> a
                    | _ -> failedPeer channel e.Side "invalid_payload"
                let received = try take node addressText { channel.Spec with Id = protocol } with ex -> failedPeer channel e.Side ex.Message
                track received, next
            | Error reason -> failedPeer channel e.Side reason
        | None ->
            match channel.Await e.Side with
            | Delegated other ->
                SessionChannel.Release other.Channel
                track other, next
            | Item _ -> fail "wrong_receive_kind"

    /// Run a body that owns some ends; if it fails, the ends it holds are
    /// given up.
    [<CompiledName("WithOwned")>]
    let withOwned (ends: SessionEnd list) (body: unit -> 'a) : 'a =
        let previous = owned.Value
        let set = Collections.Generic.HashSet<SessionEnd>(HashIdentity.Reference)
        for e in ends do set.Add e |> ignore
        owned.Value <- set
        try
            try body ()
            with _ ->
                for e in List.ofSeq (lock set (fun () -> List.ofSeq set)) do SessionChannel.Discard e
                reraise ()
        finally
            owned.Value <- previous

    /// Start a task with an end it now owns.
    [<CompiledName("Spawn")>]
    let spawn (e: SessionEnd) (body: SessionEnd -> Value) : SessionTask =
        let moved = transfer e
        let set = Collections.Generic.HashSet<SessionEnd>(HashIdentity.Reference)
        set.Add moved |> ignore
        let work =
            Task.Run(fun () ->
                owned.Value <- set
                try body moved
                with _ ->
                    for o in lock set (fun () -> List.ofSeq set) do SessionChannel.Discard o
                    reraise ())
        SessionTask(work, set)

    /// Wait for a task's result (its failure is raised here).
    [<CompiledName("Join")>]
    let join (task: SessionTask) : Value =
        try task.Work.Result with
        | :? AggregateException as e when e.InnerExceptions.Count = 1 -> raise e.InnerExceptions.[0]

    /// Cancel a task: the ends it still owns are given up, so it stops at its next step.
    [<CompiledName("Cancel")>]
    let cancel (task: SessionTask) =
        for o in lock task.Owned (fun () -> List.ofSeq task.Owned) do SessionChannel.Discard o
        (try task.Work.Wait(5000) |> ignore with _ -> ())
