/// Scenario values use the same canonical frames, reliable endpoints and
/// mailbox receipts as native distribution. Only causal metadata stays beside
/// the transport: channel clocks follow sequence order, and mailbox clocks
/// follow the actual source/request identity, even after reordering.
/// ref:DEC-distribution-canonical-wire ref:DEC-stateful-models-linearizability
module LawSpec.Testing.ScenarioNetwork

open System.Numerics
open System.Text
open LawSpec.Runtime
open LawSpec.Runtime.Descriptors

/// A channel end (channel, side) or a mailbox of a scenario.
type Destination =
    | EndOf of channel: string * side: int
    | MailboxOf of name: string

/// What a scenario sends: a value, or a channel end it hands over.
type Payload =
    | Plain of Value
    | Moved of channel: string * side: int

/// A vector clock: each process's count of steps.
type Clock = Map<string, int64>

/// What the network's services report, posted to the scenario's hub.
type Incoming =
    | ChannelResult of Destination * ticket: int64 * Result<byte[], string>
    | MailFrame of Destination * Node * Wire.Frame
    /// A mailbox request's reply; its identity is set once the request is made.
    | MailReply of identity: uint64 ref * Result<int * byte[], string>

/// What a report means for the hub's queues.
type Outcome =
    | Delivered of Destination * Payload * Clock
    | Lost of Destination * Payload
    | Gone of Destination

/// Frame counts of a run over the network.
type Stats =
    {
        Frames: int
        Lost: int
        Duplicated: int
        PendingRequests: int
    }

type private EndEntry =
    {
        Endpoint: Endpoint
        mutable Sends: Descriptor list
        mutable Receives: Descriptor list
        Clocks: System.Collections.Generic.Queue<Payload * Clock>
        mutable Ticket: int64 option
    }

type private Box =
    {
        Sender: Node
        Address: string
        Type: Descriptor
    }

type private Flight =
    {
        Destination: Destination
        Value: Payload
        Clock: Clock
    }

let private fail reason : 'a = Fail.raiseWith "ScenarioNetwork" reason

let private require condition reason =
    if not condition then
        fail reason

let private unquote d =
    match d with
    | Quoted q -> q
    | Atom a -> a
    | _ -> fail "invalid_wire"

/// The network of one scenario run: a seeded faulty memory network, a node per
/// channel end and two per mailbox. Only the hub calls it, one call at a time.
[<Sealed>]
type ScenarioNetwork
    (
        channels: string list,
        mailboxes: string list,
        wire: Descriptor list option,
        shake: BigInteger,
        faults: MemoryOptions -> MemoryOptions,
        deadline: int,
        post: Incoming -> unit
    ) =
    let forms =
        match wire with
        | Some forms -> forms
        | None when List.isEmpty channels && List.isEmpty mailboxes -> []
        | None -> fail "scenario_wire_required"

    let steps =
        forms
        |> List.choose (function
            | Forms(Atom "channel" :: n :: ss) -> Some(unquote n, ss)
            | _ -> None)
        |> Map.ofList

    let types =
        forms
        |> List.choose (function
            | Forms [ Atom "mailbox"; n; d ] -> Some(unquote n, d)
            | _ -> None)
        |> Map.ofList

    do
        require (List.sort (List.ofSeq steps.Keys) = List.sort channels) "channel_wire_required"
        require (List.sort (List.ofSeq types.Keys) = List.sort mailboxes) "mailbox_wire_required"

    let table =
        forms
        |> List.choose (function
            | Forms(Atom "data" :: n :: _) as d -> Some(unquote n, d)
            | _ -> None)
        |> Map.ofList

    let defaults: MemoryOptions =
        {
            Seed = shake ^^^ BigInteger 0x7f4a7c159e3779b9UL
            Loss = 0.1
            Duplicate = 0.1
            Delay = 0.002
            Record = true
        }

    let network = new MemoryNetwork(faults defaults)
    let nodes = ResizeArray<Node>()
    let ends = System.Collections.Generic.Dictionary<Destination, EndEntry>()
    let boxes = System.Collections.Generic.Dictionary<Destination, Box>()
    let flights = System.Collections.Generic.Dictionary<string * uint64, Flight>()

    let pending =
        System.Collections.Generic.Dictionary<uint64, (Result<unit, string> -> unit) * (string * uint64) * Node>()

    let addNode () =
        let node =
            new Node(Transports.insecureMemoryForTests network ("scenario-" + string nodes.Count), NetworkConfig.empty)

        nodes.Add node
        node

    let listen destination (entry: EndEntry) =
        let ticket = ref 0L

        ticket.Value <-
            entry.Endpoint.ReceiveAsync(None, fun result -> post (ChannelResult(destination, ticket.Value, result)))

        entry.Ticket <- Some ticket.Value

    let addEnd name side (ss: Descriptor list) =
        let node = addNode ()
        let endpoint = new Endpoint(node, "end", deadline)

        let verbs =
            ss
            |> List.map (function
                | Forms [ Atom verb; d ] -> verb = "send", d
                | _ -> fail "invalid_wire")

        let entry =
            {
                Endpoint = endpoint
                Sends = verbs |> List.filter (fun (s, _) -> s = (side = 0)) |> List.map snd
                Receives = verbs |> List.filter (fun (s, _) -> s <> (side = 0)) |> List.map snd
                Clocks = System.Collections.Generic.Queue()
                Ticket = None
            }

        ends.[EndOf(name, side)] <- entry
        listen (EndOf(name, side)) entry
        endpoint

    do
        for name in channels do
            let a = addEnd name 0 steps.[name]
            let b = addEnd name 1 steps.[name]
            b.Connect a.Address

        for name in List.sort mailboxes do
            let owner = addNode ()
            let sender = addNode ()
            let destination = MailboxOf name

            let address =
                owner.RegisterReceiver("mail", fun frame -> post (MailFrame(destination, owner, frame)))

            boxes.[destination] <-
                {
                    Sender = sender
                    Address = address
                    Type = types.[name]
                }

    let encode (d: Descriptor) (payload: Payload) =
        match d, payload with
        | Forms [ Atom "end" ], Moved(name, side) ->
            require (ends.ContainsKey(EndOf(name, side))) "unknown_delegated_end"
            Descriptors.encode (Forms [ Atom "text" ]) (Text(name + "#" + string side)) Map.empty
        | _, Plain value -> Descriptors.encode d value table
        | _ -> fail "invalid_payload"

    let decode (d: Descriptor) (bytes: byte[]) =
        match d with
        | Forms [ Atom "end" ] ->
            match Descriptors.decode (Forms [ Atom "text" ]) bytes Map.empty with
            | Text address ->
                let at = address.LastIndexOf '#'
                require (at >= 0) "unknown_delegated_end"
                let name, side = address.Substring(0, at), int (address.Substring(at + 1))
                require (ends.ContainsKey(EndOf(name, side))) "unknown_delegated_end"
                Moved(name, side)
            | _ -> fail "unknown_delegated_end"
        | _ -> Plain(Descriptors.decode d bytes table)

    /// Send from an end, or to a mailbox (whose reply comes later).
    member _.Send
        (destination: Destination, payload: Payload, clock: Clock, reply: Result<unit, string> -> unit)
        : bool =
        match destination with
        | EndOf(name, side) ->
            let entry = ends.[destination]

            match entry.Sends with
            | d :: rest ->
                entry.Endpoint.Send(encode d payload)
                entry.Sends <- rest
                ends.[EndOf(name, 1 - side)].Clocks.Enqueue((payload, clock))
                true
            | [] -> fail "protocol_complete"
        | MailboxOf _ ->
            let box = boxes.[destination]
            let bytes = encode box.Type payload
            let cell = ref 0UL

            let identity =
                box.Sender.RequestAsync(
                    box.Address,
                    "mail",
                    bytes,
                    deadline,
                    fun result -> post (MailReply(cell, result))
                )

            cell.Value <- identity
            let key = box.Sender.Address, identity

            flights.[key] <-
                {
                    Destination = destination
                    Value = payload
                    Clock = clock
                }

            pending.[identity] <- (reply, key, box.Sender)
            false

    member _.Abandon(destination: Destination) =
        match destination with
        | EndOf _ -> ends.[destination].Endpoint.Abandon()
        | MailboxOf _ -> ()

    /// What an incoming report means.
    member this.Event(incoming: Incoming) : Outcome list =
        match incoming with
        | ChannelResult(destination, ticket, result) ->
            match ends.TryGetValue destination with
            | true, entry when entry.Ticket = Some ticket ->
                match result with
                | Ok bytes ->
                    match entry.Receives with
                    | d :: rest ->
                        let payload, clock = entry.Clocks.Dequeue()
                        let value = decode d bytes
                        entry.Receives <- rest
                        listen destination entry
                        ignore payload
                        [ Delivered(destination, value, clock) ]
                    | [] -> fail "protocol_complete"
                | Error _ ->
                    let lost = [ for payload, _ in entry.Clocks -> Lost(destination, payload) ]
                    entry.Clocks.Clear()
                    entry.Ticket <- None
                    lost @ [ Gone destination ]
            | _ -> []
        | MailFrame(destination, owner, frame) ->
            match flights.TryGetValue((frame.Source, frame.Id)) with
            | true, flight when flight.Destination = destination && frame.Kind = "mail" ->
                let value = Plain(Descriptors.decode boxes.[destination].Type frame.Payload table)
                owner.Reply(frame.Source, frame.Id, 0, [||])
                flights.Remove((frame.Source, frame.Id)) |> ignore
                [ Delivered(destination, value, flight.Clock) ]
            | _ ->
                if frame.Id <> 0UL then
                    owner.Reply(frame.Source, frame.Id, 3, Encoding.UTF8.GetBytes "not a scenario mailbox request")

                []
        | MailReply(cell, result) -> this.Replied(cell, result)

    /// A mailbox reply, by the request identity it answers.
    member _.Replied(cell: uint64 ref, result: Result<int * byte[], string>) : Outcome list =
        let identity = cell.Value

        match pending.TryGetValue identity with
        | true, (reply, key, _) ->
            pending.Remove identity |> ignore

            reply (
                match result with
                | Ok(0, body) when body.Length = 0 -> Ok()
                | _ -> Error(sprintf "mailbox_send_failed %A" result)
            )
            // A timed-out request may never have arrived: release what it carried.
            match flights.TryGetValue key with
            | true, flight ->
                flights.Remove key |> ignore
                [ Lost(flight.Destination, flight.Value) ]
            | _ -> []
        | _ -> []

    member _.Stats() =
        let trace = network.Trace()

        {
            Frames = trace.Length
            Lost = trace |> List.filter (fun e -> e.Outcome = "lost") |> List.length
            Duplicated = trace |> List.filter (fun e -> List.length e.DelaySlots = 2) |> List.length
            PendingRequests = pending.Count
        }

    member _.Close() =
        for KeyValue(_, (reply, _, _)) in List.ofSeq pending do
            reply (Error "network_closed")

        pending.Clear()

        for node in nodes do
            (try
                node.Close()
             with _ ->
                 ())

        network.Close()
