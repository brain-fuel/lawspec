namespace LawSpec.Runtime

open System
open System.Diagnostics
open System.Security.Cryptography
open System.Threading
open System.Threading.Tasks
open LawSpec.Runtime.ChannelProtocol

type private Reader =
    { Ticket: int64
      Respond: Result<byte[], string> -> unit
      mutable Timer: Timer }

/// A reliable channel end a node owns: its protocol state, its retry timer
/// and its reader. Giving up is an ordered frame that keeps retrying after
/// the application leaves; an unused end can move to another node.
/// ref:DEC-distribution-canonical-wire ref:DEC-sessions-by-construction
[<Sealed; AllowNullLiteral>]
type Endpoint(node: Node, name: string, deadline: int) as this =
    do if deadline <= 0 then Fail.raiseWith "Channel" "invalid_deadline"
    let gate = obj ()
    let mutable protocol = Unchecked.defaultof<ChannelState>
    let mutable reader: Reader option = None
    let mutable taking: (Result<unit, string> -> unit) option = None
    let mutable timer: Timer = null
    let mutable tickets = 0L
    let mutable stopped = false
    let now () = Stopwatch.GetTimestamp() * 1_000_000L / Stopwatch.Frequency
    let fail reason : 'a = Fail.raiseWith "Channel" reason
    let address = node.RegisterReceiver(name, fun frame -> this.Arrive frame)
    do
        protocol <- ChannelProtocol.create address (int64 deadline * 1000L)
        node.Adopt this

    /// Settle waiters and the timer; return what to do outside the lock.
    member private this.Wake() : (unit -> unit) list =
        let actions = ResizeArray<unit -> unit>()
        match taking with
        | Some respond ->
            match takeStatus protocol (now ()) with
            | Ok false -> ()
            | Ok true ->
                taking <- None
                actions.Add(fun () -> respond (Ok()))
            | Error reason ->
                taking <- None
                actions.Add(fun () -> respond (Error reason))
        | None ->
            match reader with
            | Some r ->
                match receiveBody protocol with
                | Empty, _ -> ()
                | result, next ->
                    protocol <- next
                    reader <- None
                    if not (isNull r.Timer) then r.Timer.Dispose()
                    let outcome = match result with Body b -> Ok b | Failed reason -> Error reason | Empty -> Error ""
                    actions.Add(fun () -> r.Respond outcome)
            | None -> ()
        let active =
            protocol.Failure.IsNone && protocol.Moved.IsNone
            && (not protocol.Unacked.IsEmpty || taking.IsSome || (protocol.Taking.IsSome && not protocol.Taken)
                || (protocol.Announcing && not protocol.Confirmed && protocol.Peer.IsSome))
        if active && isNull timer && not stopped then
            timer <- new Timer((fun _ -> this.Tick()), null, 10, 10)
        elif not active && not (isNull timer) then
            timer.Dispose()
            timer <- null
        List.ofSeq actions

    member private this.Update(transition: ChannelState -> ChannelState * Wire.Frame list) =
        let frames, actions =
            lock gate (fun () ->
                let next, frames = transition protocol
                protocol <- next
                frames, this.Wake())
        for frame in frames do (try node.Forward frame with _ -> ())
        for action in actions do action ()

    member private this.Tick() = this.Update(fun state -> tick state (now ()))

    member private this.Arrive(frame: Wire.Frame) = this.Update(fun state -> accept state frame (now ()))

    member private this.Guard(operation: unit -> 'a) =
        try operation () with
        | :? LawSpecException as e when e.Code = "Channel" -> raise e
        | :? LawSpecException as e when e.Code = "ChannelEndUnavailable" -> fail "channel_end_unavailable"
        | _ -> fail "invalid_operation"

    member private this.Idle() = if taking.IsSome then fail "taking_in_progress"

    /// The end's address.
    member _.Address = address

    member this.Connect(peer: string) =
        this.Guard(fun () ->
            lock gate (fun () -> this.Idle())
            this.Update(fun state -> connect state peer (now ())))

    member this.Send(bytes: byte[]) =
        this.Guard(fun () ->
            lock gate (fun () -> this.Idle())
            this.Update(fun state -> send state bytes (now ())))

    member this.Abandon() = this.Update(fun state -> abandon state (now ()))

    /// Wait for the next value (timeout in ms, or none): its bytes, or why
    /// there is none.
    member this.ReceiveAsync(timeout: int option, respond: Result<byte[], string> -> unit) : int64 =
        let ticket =
            lock gate (fun () ->
                this.Idle()
                if reader.IsSome then fail "already_receiving"
                tickets <- tickets + 1L
                let r = { Ticket = tickets; Respond = respond; Timer = null }
                reader <- Some r
                match timeout with
                | Some ms ->
                    r.Timer <-
                        new Timer((fun _ ->
                            let fire =
                                lock gate (fun () ->
                                    match reader with
                                    | Some current when current.Ticket = r.Ticket ->
                                        reader <- None
                                        true
                                    | _ -> false)
                            if fire then respond (Error "receive_timeout")), null, ms, Timeout.Infinite)
                | None -> ()
                tickets)
        this.Update(fun state -> state, [])
        ticket

    /// Wait for the next value's bytes.
    member this.Receive(timeout: int option) : Result<byte[], string> =
        let result = TaskCompletionSource<Result<byte[], string>>(TaskCreationOptions.RunContinuationsAsynchronously)
        this.ReceiveAsync(timeout, result.SetResult) |> ignore
        result.Task.Result

    /// Stop waiting; the reader is not called.
    member this.Cancel(ticket: int64) =
        lock gate (fun () ->
            match reader with
            | Some r when r.Ticket = ticket ->
                if not (isNull r.Timer) then r.Timer.Dispose()
                reader <- None
            | _ -> ())

    /// Offer this unused end to another node; the address that takes it.
    member this.Offer() : string =
        this.Guard(fun () ->
            lock gate (fun () ->
                this.Idle()
                if reader.IsSome then fail "already_receiving"
                let address, next = offer protocol (Convert.ToHexString(RandomNumberGenerator.GetBytes 32))
                protocol <- next
                address))

    /// Take an offered end into this fresh one, waiting until it arrives.
    member this.Take(offered: string) =
        let result = TaskCompletionSource<Result<unit, string>>(TaskCreationOptions.RunContinuationsAsynchronously)
        this.Guard(fun () ->
            lock gate (fun () ->
                this.Idle()
                if reader.IsSome then fail "already_receiving"
                if protocol.Peer.IsSome || not protocol.Unacked.IsEmpty || protocol.Expected <> 0L || protocol.Taking.IsSome then
                    fail "end_not_fresh"
                taking <- Some result.SetResult)
            this.Update(fun state -> take state offered (now ())))
        match result.Task.Result with
        | Ok() -> ()
        | Error reason -> fail reason

    /// Destroy the end (a conversation ends with Abandon).
    member this.Stop() =
        let waiting =
            lock gate (fun () ->
                stopped <- true
                if not (isNull timer) then timer.Dispose()
                timer <- null
                let r = reader
                reader <- None
                let t = taking
                taking <- None
                r, t)
        match waiting with
        | r, t ->
            r |> Option.iter (fun r -> r.Respond(Error "endpoint_closed"))
            t |> Option.iter (fun t -> t (Error "endpoint_closed"))
        try node.Unregister name with _ -> ()

    interface IDisposable with
        member this.Dispose() = this.Stop()
