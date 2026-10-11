/// Pure transitions of a reliable, movable network channel end. Its owner
/// keeps the timers and sends the frames each transition returns.
/// Application values enter as canonical bytes and leave in send order,
/// exactly once; an end that has not been used can move to another node with
/// its state, and its peer follows it. Times are monotonic microseconds.
/// ref:DEC-distribution-canonical-wire ref:DEC-sessions-by-construction
module LawSpec.Runtime.ChannelProtocol

open System
open System.Numerics
open LawSpec.Runtime.Wire

let private retry = 50000L

type Unacked = { Body: byte[]; First: int64; Last: int64 }

type Taking = { From: string; Token: string; First: int64; Last: int64 }

type ChannelState =
    { Address: string
      Deadline: int64
      Peer: string option
      Out: int64
      Expected: int64
      Unacked: Map<int64, Unacked>
      Early: Map<int64, byte[]>
      Received: byte[] list
      Failure: string option
      Closed: bool
      Eof: bool
      Used: bool
      History: string list
      Token: string option
      Moved: string option
      Snapshot: byte[] option
      Taking: Taking option
      Taken: bool
      Confirmed: bool
      Announcing: bool
      AnnouncedAt: int64 option }

/// What a reader gets.
type Received =
    | Empty
    | Body of byte[]
    | Failed of string

let private unavailable () : 'a = Fail.raiseWith "ChannelEndUnavailable" ""
let private check condition = if not condition then Fail.raiseWith "InvalidChannelOperation" ""
[<CompiledName("EofReason")>]
let eofReason = "the other end gave up the conversation"
[<CompiledName("TakeFailure")>]
let takeFailure = "the node the end came from did not hand it over in time (unreachable)"

/// A new end at an address; the deadline is in microseconds.
[<CompiledName("Create")>]
let create (address: string) (deadline: int64) =
    splitAddress address |> ignore
    check (deadline > 0L)
    { Address = address; Deadline = deadline; Peer = None; Out = 0L; Expected = 0L; Unacked = Map.empty
      Early = Map.empty; Received = []; Failure = None; Closed = false; Eof = false; Used = false; History = []
      Token = None; Moved = None; Snapshot = None; Taking = None; Taken = false; Confirmed = false
      Announcing = false; AnnouncedAt = None }

let private message (destination: string) (kind: string) (payload: byte[]) = frameTo destination kind payload

let private usable (state: ChannelState) =
    if state.Eof then unavailable ()
    match state.Failure, state.Closed, state.Token, state.Moved, state.Taking, state.Taken with
    | None, false, None, None, None, _ -> ()
    | None, false, None, None, _, true -> ()
    | _ -> unavailable ()

let private channelFrame (state: ChannelState) (sequence: int64) (body: byte[]) =
    message state.Peer.Value "chan" (channel sequence state.Address body)

let private transmit (state: ChannelState) (sequence: int64) (body: byte[]) (now: int64) =
    channel sequence state.Address body |> ignore
    let next = { state with Unacked = state.Unacked.Add(sequence, { Body = body; First = now; Last = now }) }
    next, (match state.Peer with None -> [] | Some _ -> [ channelFrame state sequence body ])

/// Greet a peer end.
[<CompiledName("Connect")>]
let connect (state: ChannelState) (peer: string) (now: int64) =
    usable state
    check state.Peer.IsNone
    splitAddress peer |> ignore
    transmit { state with Peer = Some peer } -1L ("hello"B) now

/// Send a value's bytes.
[<CompiledName("Send")>]
let send (state: ChannelState) (bytes: byte[]) (now: int64) =
    usable state
    transmit { state with Out = state.Out + 1L; Used = true } state.Out (Array.append [| 0uy |] bytes) now

/// Give up the conversation: an ordered end-of-file frame.
[<CompiledName("Abandon")>]
let abandon (state: ChannelState) (now: int64) =
    if state.Closed || state.Moved.IsSome then state, []
    else
        match state.Failure with
        | None -> transmit { state with Out = state.Out + 1L; Closed = true } state.Out [| 1uy |] now
        | Some _ -> { state with Closed = true }, []

/// The next value for a reader, if there is one.
[<CompiledName("ReceiveBody")>]
let receiveBody (state: ChannelState) : Received * ChannelState =
    if state.Token.IsSome || state.Moved.IsSome then Failed "the channel end has been offered or moved", state
    else
        match state.Received with
        | body :: rest when body.Length >= 1 && body.[0] = 0uy -> Body body.[1..], { state with Received = rest; Used = true }
        | _ :: _ -> Failed eofReason, { state with Received = []; Used = true; Eof = true }
        | [] ->
            match state.Eof, state.Failure with
            | true, _ -> Failed eofReason, state
            | false, None -> Empty, state
            | false, Some reason -> Failed reason, state

let private validBody (body: byte[]) = (body.Length >= 1 && body.[0] = 0uy) || (body.Length = 1 && body.[0] = 1uy)

let rec private drain (state: ChannelState) =
    match state.Early.TryFind state.Expected with
    | Some body ->
        drain { state with Expected = state.Expected + 1L; Early = state.Early.Remove state.Expected; Received = state.Received @ [ body ] }
    | None -> state

let private fail (reason: string) (state: ChannelState) =
    match state.Failure with
    | None -> { state with Failure = Some reason; Unacked = Map.empty }
    | Some _ -> state

let private seqType = sequenceType
let private textType' = textType
let private bytesType' = bytesType

let private empty (value: string option) = defaultArg value ""
let private optional (value: string) = if value = "" then None else Some value

let private numbered (entries: (int64 * byte[]) list) =
    Array.concat (
        Descriptors.varint (BigInteger(List.length entries))
        :: [ for n, body in entries -> fields [ seqType; bytesType' ] [ Int(BigInteger n); Bytes body ] ])

let private readNumbered (bytes: byte[]) (start: int) =
    let count, position = Descriptors.readVarint bytes start
    check (count <= BigInteger((bytes.Length - position) / 2))
    let mutable at = position
    let entries =
        [ for _ in 1 .. int count ->
              match readFields [ seqType; bytesType' ] bytes at with
              | [ Int n; Bytes body ], next ->
                  at <- next
                  int64 n, body
              | _ -> Fail.raiseWith "InvalidSnapshot" "" ]
    entries, at

let private snapshot (state: ChannelState) =
    let prefix =
        fields [ textType'; textType'; textType'; Descriptors.Forms [ Descriptors.Atom "list"; textType' ]; seqType; seqType ]
            [ Text(empty state.Token); Text(empty state.Failure); Text(empty state.Peer)
              Value.List((state.History @ [ state.Address ]) |> List.map Text); Int(BigInteger state.Out); Int(BigInteger state.Expected) ]
    let unacked = [ for KeyValue(n, e) in state.Unacked -> n, e.Body ]
    let early = [ for KeyValue(n, b) in state.Early -> n, b ]
    Array.concat [ prefix; numbered unacked; numbered early; bytesList state.Received ]

let rec private tickTaking (state: ChannelState) (taking: Taking) (now: int64) =
    if now - taking.First >= state.Deadline then fail takeFailure state, []
    elif now - taking.Last > retry then
        let payload = texts [ taking.Token; state.Address ]
        { state with Taking = Some { taking with Last = now } }, [ message taking.From "take" payload ]
    else state, []

and private announce (state: ChannelState) (now: int64) =
    match state.Announcing, state.Confirmed, state.AnnouncedAt with
    | true, false, at when at.IsNone || now - at.Value > retry ->
        let payload =
            Array.append (textList state.History) (texts [ state.Address ])
        { state with AnnouncedAt = Some now }, [ message state.Peer.Value "moved" payload ]
    | _ -> state, []

/// Retransmit what is due, fail what is overdue, and keep a take going.
and [<CompiledName("Tick")>] tick (state: ChannelState) (now: int64) : ChannelState * Frame list =
    if state.Moved.IsSome || state.Failure.IsSome then state, []
    else
        match state.Taking with
        | Some taking when not state.Taken -> tickTaking state taking now
        | _ ->
            let due = [ for KeyValue(n, e) in state.Unacked do if now - e.Last > retry then yield n, e ]
            let stale = due |> List.exists (fun (_, e) -> now - e.First > state.Deadline)
            if stale then fail "the other end did not answer in time (unreachable)" state, []
            elif state.Peer.IsNone then state, []
            else
                let s1, announced = announce state now
                let frames = [ for n, e in due -> channelFrame s1 n e.Body ]
                let unacked = due |> List.fold (fun (m: Map<int64, Unacked>) (n, e) -> m.Add(n, { e with Last = now })) s1.Unacked
                { s1 with Unacked = unacked }, announced @ frames

let private give (state: ChannelState) (payload: byte[]) =
    match readTexts 2 payload 0 with
    | [ token; taker ], next when next = payload.Length ->
        splitAddress taker |> ignore
        if state.Token <> Some token then state, []
        else
            match state.Moved with
            | None ->
                let snap = snapshot state
                { state with Moved = Some taker; Snapshot = Some snap; Unacked = Map.empty; Early = Map.empty }, [ message taker "state" snap ]
            | Some moved when moved = taker -> state, [ message taker "state" state.Snapshot.Value ]
            | Some _ -> state, []
    | _ -> state, []

let private install (state: ChannelState) (payload: byte[]) (now: int64) =
    let taking = state.Taking.Value
    match readTexts 3 payload 0 with
    | [ token; failure; peer ], r1 when token = taking.Token ->
        let history, r2 = readTextList payload r1
        check (not (List.isEmpty history) && List.last history = taking.From)
        history |> List.iter (splitAddress >> ignore)
        if peer <> "" then splitAddress peer |> ignore
        let outExpected, r3 = readFields [ seqType; seqType ] payload r2
        let out, expected =
            match outExpected with
            | [ Int o; Int e ] -> int64 o, int64 e
            | _ -> Fail.raiseWith "InvalidSnapshot" ""
        check (out >= 0L && expected >= 0L)
        let unacked, r4 = readNumbered payload r3
        let early, r5 = readNumbered payload r4
        let received, r6 = readBytesList payload r5
        check (r6 = payload.Length)
        check (received |> List.forall validBody)
        check (early |> List.forall (fun (n, b) -> n >= expected && validBody b))
        check (unacked |> List.forall (fun (n, b) -> (n = -1L && b = "hello"B) || (n >= 0L && n < out && validBody b)))
        check ((unacked |> List.map fst |> List.distinct |> List.length) = List.length unacked)
        check ((early |> List.map fst |> List.distinct |> List.length) = List.length early)
        let pend = unacked |> List.map (fun (n, b) -> n, { Body = b; First = now; Last = now - retry - 1L }) |> Map.ofList
        let s1 =
            { state with
                Peer = optional peer; History = history; Out = out; Expected = expected; Unacked = pend
                Early = Map.ofList early; Received = received; Announcing = true; AnnouncedAt = None; Taken = true }
        if failure = "" then tick (drain s1) now else fail failure s1, []
    | _ -> state, []

let private peerMoved (state: ChannelState) (payload: byte[]) =
    let history, rest = readTextList payload 0
    match readTexts 1 payload rest with
    | [ destination ], next when next = payload.Length ->
        splitAddress destination |> ignore
        let s1 =
            match state.Peer with
            | None -> { state with Peer = Some destination }
            | Some p when List.contains p history -> { state with Peer = Some destination }
            | _ -> state
        if s1.Peer = Some destination then
            s1, [ message destination "moved-ack" (Descriptors.encode textType' (Text destination) Map.empty) ]
        else s1, []
    | _ -> state, []

let private arriving (state: ChannelState) (frame: Frame) (now: int64) =
    match frame.Kind with
    | "take" -> give state frame.Payload
    | _ when state.Moved.IsSome -> state, [ { frame with To = state.Moved.Value } ]
    | _ when state.Taking.IsSome && not state.Taken ->
        if frame.Kind = "state" then install state frame.Payload now else state, []
    | "chan" when state.Failure.IsSome -> state, []
    | "ack" -> { state with Unacked = state.Unacked.Remove(readSequence frame.Payload) }, []
    | "moved" -> peerMoved state frame.Payload
    | "moved-ack" ->
        (match readTexts 1 frame.Payload 0 with
         | [ address ], next when next = frame.Payload.Length && address = state.Address -> { state with Confirmed = true }, []
         | _ -> state, [])
    | "chan" ->
        let sequence, sender, body = readChannel frame.Payload
        splitAddress sender |> ignore
        let updated =
            if sequence = -1L then
                check (body = "hello"B)
                if state.Peer.IsNone then { state with Peer = Some sender } else state
            else
                check (sequence >= 0L && validBody body)
                check (not state.Eof || sequence < state.Expected)
                if sequence >= state.Expected && not (state.Early.ContainsKey sequence) then
                    drain { state with Early = state.Early.Add(sequence, body) }
                else state
        updated, [ message sender "ack" (Wire.sequence sequence) ]
    | _ -> state, []

/// A frame for this end. Invalid frames change nothing.
[<CompiledName("Accept")>]
let accept (state: ChannelState) (frame: Frame) (now: int64) =
    try arriving state frame now with _ -> state, []

/// Offer an unused end to another node: the address that takes it.
[<CompiledName("Offer")>]
let offer (state: ChannelState) (token: string) =
    check (token <> "" && not state.Used && not state.Closed && state.Moved.IsNone && (state.Taking.IsNone || state.Taken))
    let chosen = defaultArg state.Token token
    state.Address + "?take=" + chosen, { state with Token = Some chosen }

/// Take an offered end, by the address its offer gave.
[<CompiledName("Take")>]
let take (state: ChannelState) (address: string) (now: int64) =
    usable state
    check (not state.Used)
    match address.IndexOf "?take=" with
    | -1 -> Fail.raiseWith "InvalidChannelOperation" ""
    | at ->
        let old, token = address.Substring(0, at), address.Substring(at + 6)
        check (token <> "")
        splitAddress old |> ignore
        tick { state with Taking = Some { From = old; Token = token; First = now; Last = now - retry - 1L } } now

/// Whether a take has finished.
[<CompiledName("TakeStatus")>]
let takeStatus (state: ChannelState) (now: int64) : Result<bool, string> =
    match state.Taking with
    | None -> Ok true
    | Some taking ->
        if state.Taken then
            Ok(state.Confirmed || state.Failure.IsSome || now - taking.First >= state.Deadline)
        elif state.Failure.IsSome || now - taking.First >= state.Deadline then Error takeFailure
        else Ok false
