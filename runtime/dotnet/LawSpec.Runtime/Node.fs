namespace LawSpec.Runtime

open System
open System.Security.Cryptography
open System.Threading
open System.Threading.Tasks
open LawSpec.Runtime.Wire

/// Something registered at a node under a name: a handler, whose answer the
/// node sends as the reply, or a receiver that answers later with Reply.
type Entity =
    | Handler of (Frame -> int * byte[])
    | Receiver of (Frame -> unit)

type private Seen =
    {
        mutable Response: byte[] option
        Entity: string
        Fingerprint: byte[]
    }

type private Arrival =
    | Resend of byte[]
    | Ignore
    | Missing
    | Dispatch of Entity

type private Pending =
    {
        Address: string
        Peer: string
        Frame: Frame
        Deadline: DateTime
        Respond: Result<int * byte[], string> -> unit
        mutable Timer: Timer
    }

/// A node: named entities reached by frames, and reliable request and reply
/// over a transport. Requests are deduplicated by sender and identity, even
/// while their handler runs, and retried until answered or out of time.
/// Handlers run in tasks the node owns. Status codes: 0 ok, 1 failed,
/// 2 stopped, 3 rejected.
/// ref:DEC-distribution-canonical-wire ref:DEC-async-native-tasks
[<Sealed; AllowNullLiteral>]
type Node(transport: Transport, options: NetworkOptions) as this =
    let gate = obj ()
    let entities = Collections.Generic.Dictionary<string, Entity>()
    let seen = Collections.Generic.Dictionary<string * uint64, Seen>()
    let pending = Collections.Generic.Dictionary<uint64, Pending>()
    let jobs = Collections.Concurrent.ConcurrentDictionary<int, Task>()
    let services = Collections.Concurrent.ConcurrentBag<IDisposable>()
    let mutable closed = false

    let mutable nextId =
        match options.FirstId with
        | Some id -> id
        | None ->
            (BitConverter.ToUInt64(RandomNumberGenerator.GetBytes 8, 0)
             &&& ((1UL <<< 61) - 1UL))
            + 1UL

    let mutable secure: SecureLayer = Unchecked.defaultof<_>
    let mutable raw: IPacketTransport = Unchecked.defaultof<_>
    let fail reason : 'a = Fail.raiseWith "Network" reason

    let fingerprint (frame: Frame) =
        SHA256.HashData(encodeFrame frame.Kind frame.To frame.Source frame.Id frame.Payload)

    do
        match transport with
        | Memory(_, _, true) -> raw <- Transports.open' transport (fun _ bytes -> this.Packet bytes)
        | _ ->
            let layer =
                new SecureLayer(SecureNetwork.crypto (), transport, options, fun _ bytes -> this.Packet bytes)

            layer.Start()
            secure <- layer

    /// The node's address: mem://name, tcp://host:port or http://host:port.
    member _.Address = if isNull (box secure) then raw.Address else secure.Address

    /// The fingerprint of the node's identity (secure nodes only).
    member _.Identity =
        if isNull (box secure) then
            fail "insecure_node"
        else
            secure.Fingerprint

    member private _.Wire(peer: string, bytes: byte[]) =
        if isNull (box secure) then
            raw.Send(peer, bytes)
        else
            secure.Send(peer, bytes)

    member private this.Transmit(frame: Frame) =
        let peer, name = splitAddress frame.To
        let source = if frame.Source = "" then this.Address else frame.Source
        this.Wire(peer, encodeFrame frame.Kind name source frame.Id frame.Payload)

    member private this.Validate(frame: Frame) =
        try
            splitAddress frame.To |> ignore
            encodeFrame frame.Kind "" frame.Source frame.Id frame.Payload |> ignore
        with _ ->
            fail "invalid_frame"

    member private this.SendReply(source: string, identity: uint64, payload: byte[]) =
        try
            this.Transmit
                {
                    Kind = "reply"
                    To = source + "/"
                    Source = ""
                    Id = identity
                    Payload = payload
                }
            |> ignore
        with _ ->
            ()

    member private this.Answer(key: string * uint64, status: int, body: byte[]) =
        let payload = Array.append [| byte status |] body

        let send =
            lock gate (fun () ->
                match seen.TryGetValue key with
                | true, entry when entry.Response.IsNone ->
                    entry.Response <- Some payload
                    true
                | _ -> false)

        if send then
            this.SendReply(fst key, snd key, payload)

    member private this.Finish(identity: uint64, result: Result<int * byte[], string> option) =
        let found =
            lock gate (fun () ->
                match pending.TryGetValue identity with
                | true, p ->
                    pending.Remove identity |> ignore

                    if not (isNull p.Timer) then
                        p.Timer.Dispose()

                    Some p
                | _ -> None)

        match found, result with
        | Some p, Some r -> p.Respond r
        | _ -> ()

    /// A packet from the transport.
    member internal this.Packet(bytes: byte[]) =
        match readFrame bytes with
        | Some frame ->
            (try
                this.Arrive frame
             with _ ->
                 ())
        | None -> ()

    member private this.Arrive(frame: Frame) =
        if frame.Kind = "reply" then
            if frame.Payload.Length >= 1 then
                let matches =
                    lock gate (fun () ->
                        match pending.TryGetValue frame.Id with
                        | true, p -> p.Peer = frame.Source
                        | _ -> false)

                if matches then
                    this.Finish(frame.Id, Some(Ok(int frame.Payload.[0], frame.Payload.[1..])))
        else
            let key = frame.Source, frame.Id

            let action =
                lock gate (fun () ->
                    match seen.TryGetValue key with
                    | true, entry when frame.Id <> 0UL ->
                        if fingerprint frame <> entry.Fingerprint then
                            Resend(
                                Array.append
                                    [| 3uy |]
                                    (Text.Encoding.UTF8.GetBytes "a request identity was reused for different content")
                            )
                        else
                            match entry.Response with
                            | Some response -> Resend response
                            | None -> Ignore
                    | _ ->
                        match entities.TryGetValue frame.To with
                        | false, _ ->
                            if frame.Id = 0UL then
                                Ignore
                            else
                                seen.[key] <-
                                    {
                                        Response = None
                                        Entity = frame.To
                                        Fingerprint = fingerprint frame
                                    }

                                Missing
                        | true, entity ->
                            if frame.Id <> 0UL then
                                seen.[key] <-
                                    {
                                        Response = None
                                        Entity = frame.To
                                        Fingerprint = fingerprint frame
                                    }

                            Dispatch entity)

            match action with
            | Resend payload -> this.SendReply(frame.Source, frame.Id, payload)
            | Ignore -> ()
            | Missing -> this.Answer(key, 3, Text.Encoding.UTF8.GetBytes("nothing is registered as " + frame.To))
            | Dispatch(Receiver receive) -> receive frame
            | Dispatch(Handler handle) ->
                let job =
                    Task.Run(fun () ->
                        let status, body =
                            try
                                let status, body = handle frame

                                if status < 0 || status > 255 then
                                    1, Text.Encoding.UTF8.GetBytes "invalid reply"
                                else
                                    status, body
                            with e ->
                                1, Text.Encoding.UTF8.GetBytes e.Message

                        if frame.Id <> 0UL then
                            this.Answer(key, status, body))

                jobs.[job.Id] <- job
                job.ContinueWith(fun (t: Task) -> jobs.TryRemove(t.Id) |> ignore) |> ignore

    member private this.Register(name: string, entity: Entity) =
        if String.IsNullOrEmpty name || name.Contains '/' then
            fail "invalid_entity_name"

        lock gate (fun () ->
            if closed then
                fail "node_closed"

            if entities.ContainsKey name then
                fail ("already_registered " + name)

            entities.[name] <- entity)

        this.Address + "/" + name

    /// Serve requests to a name with a handler of each frame; its answer is
    /// the reply's status and body. The entity's address.
    member this.RegisterHandler(name: string, handler: Frame -> int * byte[]) = this.Register(name, Handler handler)

    /// Deliver each frame for a name to a receiver, which answers with Reply.
    member this.RegisterReceiver(name: string, receiver: Frame -> unit) = this.Register(name, Receiver receiver)

    /// A service the node closes when it closes.
    member internal this.Adopt(service: IDisposable) = services.Add service

    /// Remove a name; requests to it still waiting are answered as stopped.
    member this.Unregister(name: string) =
        let waiting =
            lock gate (fun () ->
                if entities.Remove name then
                    [
                        for KeyValue(key, entry) in seen do
                            if entry.Entity = name && entry.Response.IsNone then
                                yield key
                    ]
                else
                    [])

        for key in waiting do
            this.Answer(key, 2, Text.Encoding.UTF8.GetBytes "the receiving entity has stopped")

    /// Send a frame of a kind to an address, with no reply.
    member this.Send(address: string, kind: string, payload: byte[]) =
        let frame = frameTo address kind payload
        this.Validate frame
        this.Transmit frame |> ignore

    /// Send a frame as given (an endpoint's protocol frames).
    member this.Forward(frame: Frame) =
        this.Validate frame
        this.Transmit frame |> ignore

    /// Request: retried every 100 ms until a reply or the timeout (ms). The
    /// callback gets the reply's status and body, or the failure. Returns
    /// the request's identity.
    member this.RequestAsync
        (address: string, kind: string, payload: byte[], timeout: int, respond: Result<int * byte[], string> -> unit)
        : uint64 =
        if timeout < 0 then
            fail "invalid_timeout"

        let peer, _ = splitAddress address

        let identity, frame =
            lock gate (fun () ->
                if closed then
                    fail "node_closed"

                let identity = nextId
                nextId <- nextId + 1UL

                let frame =
                    {
                        Kind = kind
                        To = address
                        Source = ""
                        Id = identity
                        Payload = payload
                    }

                this.Validate frame

                let p =
                    {
                        Address = address
                        Peer = peer
                        Frame = frame
                        Deadline = DateTime.UtcNow.AddMilliseconds(float timeout)
                        Respond = respond
                        Timer = null
                    }

                pending.[identity] <- p
                let period = max 1 (min 100 timeout)

                p.Timer <-
                    new Timer(
                        (fun _ ->
                            let resend =
                                lock gate (fun () ->
                                    match pending.TryGetValue identity with
                                    | true, q when DateTime.UtcNow >= q.Deadline -> Some false
                                    | true, _ -> Some true
                                    | _ -> None)

                            match resend with
                            | Some true -> this.Transmit frame |> ignore
                            | Some false -> this.Finish(identity, Some(Error("unreachable " + address)))
                            | None -> ()),
                        null,
                        period,
                        period
                    )

                identity, frame)

        this.Transmit frame |> ignore
        identity

    /// Request and wait for the reply's status and body.
    member this.Request(address: string, kind: string, payload: byte[], timeout: int) : int * byte[] =
        let result =
            TaskCompletionSource<Result<int * byte[], string>>(TaskCreationOptions.RunContinuationsAsynchronously)

        this.RequestAsync(address, kind, payload, timeout, result.SetResult >> ignore)
        |> ignore

        match result.Task.Result with
        | Ok reply -> reply
        | Error reason -> fail reason

    /// Forget a request; its callback is not called.
    member this.Cancel(identity: uint64) = this.Finish(identity, None)

    /// Answer a request a receiver was given.
    member this.Reply(source: string, identity: uint64, status: int, body: byte[]) =
        if status < 0 || status > 255 then
            fail "invalid_reply"

        if identity <> 0UL then
            this.Answer((source, identity), status, body)

    /// Close the node: its services, its waiting requests and its transport.
    member this.Close() =
        let waiting =
            lock gate (fun () ->
                if closed then
                    []
                else
                    closed <- true
                    let all = List.ofSeq pending.Values
                    pending.Clear()
                    all)

        for service in services do
            (try
                service.Dispose()
             with _ ->
                 ())

        for p in waiting do
            if not (isNull p.Timer) then
                p.Timer.Dispose()

            p.Respond(Error "node_closed")

        (try
            Task.WaitAll(Array.ofSeq jobs.Values, 5000) |> ignore
         with _ ->
             ())

        if isNull (box secure) then
            raw.Dispose()
        else
            secure.Close()

    interface IDisposable with
        member this.Dispose() = this.Close()
