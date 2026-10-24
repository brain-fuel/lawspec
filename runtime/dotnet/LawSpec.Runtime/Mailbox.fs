namespace LawSpec.Runtime

open System
open System.Diagnostics
open System.Threading
open System.Threading.Tasks
open System.Numerics
open System.Text

/// A typed mailbox of portable values. Native conversion and Clock callbacks
/// run in the caller; the queue never runs application code. Closing refuses
/// new sends and lets accepted values drain. A served mailbox belongs to its
/// node, and a remote send completes once the mailbox has the value.
/// ref:DEC-actors-otp-supervision ref:DEC-distribution-canonical-wire
[<Sealed; AllowNullLiteral>]
type Mailbox private (network: (Node * string * Map<string, Descriptors.Descriptor> * Descriptors.Descriptor) option) as this
    =
    let gate = obj ()
    let queue = Collections.Generic.Queue<Value>()
    let mutable closed = false
    let mutable stopped = false
    let mutable reader: TaskCompletionSource<Result<Value, string>> option = None
    let fail reason : 'a = Fail.raiseWith "Mailbox" reason

    let address =
        match network with
        | None -> None
        | Some(node, name, _, _) ->
            let a = node.RegisterReceiver(name, fun frame -> this.Incoming frame)
            node.Adopt this
            Some a

    /// A local mailbox.
    new() = new Mailbox(None)

    /// A mailbox served at a name on a node, of values of a descriptor text.
    static member Serve(node: Node, name: string, descriptor: string) =
        let table, d = Descriptors.fromText descriptor
        new Mailbox(Some(node, name, table, d))

    member private this.Incoming(frame: Wire.Frame) =
        let node, _, table, d =
            match network with
            | Some n -> n
            | None -> fail "local_mailbox"

        let status, body =
            if closed then
                2, "the mailbox is closed"
            elif frame.Kind <> "mail" then
                3, "not a mailbox request"
            else
                try
                    this.Enqueue(Descriptors.decode d frame.Payload table)
                    0, ""
                with _ ->
                    3, "not a message of this mailbox"

        if frame.Id <> 0UL then
            node.Reply(frame.Source, frame.Id, status, Encoding.UTF8.GetBytes body)

    member private this.Enqueue(value: Value) =
        let waiting =
            lock gate (fun () ->
                match reader with
                | Some r ->
                    reader <- None
                    Some r
                | None ->
                    queue.Enqueue value
                    None)

        waiting |> Option.iter (fun r -> r.TrySetResult(Ok value) |> ignore)

    /// The served mailbox's address.
    member _.Address =
        match address with
        | Some a -> a
        | None -> fail "local_mailbox"

    /// Add a value, unless the mailbox is closed.
    member this.Send(value: Value) =
        lock gate (fun () ->
            if closed || stopped then
                fail "closed")

        this.Enqueue value

    member private this.Wait(deadline: int64 option) : Value option =
        let pending =
            lock gate (fun () ->
                if reader.IsSome then
                    fail "already_receiving"

                if queue.Count > 0 then
                    Choice1Of2(Some(queue.Dequeue()))
                elif closed || stopped then
                    fail "closed"
                else
                    let r =
                        TaskCompletionSource<Result<Value, string>>(TaskCreationOptions.RunContinuationsAsynchronously)

                    reader <- Some r
                    Choice2Of2 r)

        match pending with
        | Choice1Of2 value -> value
        | Choice2Of2 r ->
            let finished =
                match deadline with
                | None -> r.Task.Wait(Timeout.Infinite)
                | Some micros ->
                    let left = micros - Stopwatch.GetTimestamp() * 1_000_000L / Stopwatch.Frequency

                    left > 0L
                    && r.Task.Wait(TimeSpan.FromMilliseconds(float ((left + 999L) / 1000L)))

            let outcome () =
                match r.Task.Result with
                | Ok v -> Some v
                | Error e -> fail e

            if finished then
                outcome ()
            else
                let raced =
                    lock gate (fun () ->
                        match reader with
                        | Some current when obj.ReferenceEquals(current, r) ->
                            reader <- None
                            false
                        | _ -> true)

                if raced then outcome () else None

    /// The next value, waiting for one.
    member this.Receive() : Value =
        match this.Wait None with
        | Some value -> value
        | None -> fail "closed"

    /// The next value within some microseconds, or none (a Maybe).
    member this.ReceiveWithin(micros: BigInteger) : Value =
        let now = Stopwatch.GetTimestamp() * 1_000_000L / Stopwatch.Frequency

        match this.Wait(Some(now + int64 (BigInteger.Max(BigInteger.Zero, micros)))) with
        | Some value -> Data("Maybe::Present", [ value ])
        | None -> Data("Maybe::Absent", [])

    /// As ReceiveWithin, timed by the Clock in scope: the real clock waits;
    /// any other clock (the virtual one) takes what is there, then sleeps.
    member this.ReceiveWithClock(micros: BigInteger, schema: Schema.Schema) : Value =
        let rec real h =
            match h with
            | Effects.Recording(_, inner) -> real inner
            | Effects.Stateful _ -> false
            | Effects.Stateless _ -> true

        let handler = Effects.handler schema "lawspec.time::ability::Clock"

        if real handler then
            this.ReceiveWithin micros
        else
            let now = Stopwatch.GetTimestamp() * 1_000_000L / Stopwatch.Frequency

            match this.Wait(Some now) with
            | Some value -> Data("Maybe::Present", [ value ])
            | None ->
                Effects.invoke
                    handler
                    schema
                    "sleep"
                    [
                        Data("lawspec.time::type::Duration::Duration", [ Int(BigInteger.Max(BigInteger.Zero, micros)) ])
                    ]
                |> ignore

                Data("Maybe::Absent", [])

    /// Refuse new values; accepted ones still drain.
    member this.Close() =
        let waiting =
            lock gate (fun () ->
                closed <- true

                if queue.Count = 0 then
                    let r = reader
                    reader <- None
                    r
                else
                    None)

        waiting |> Option.iter (fun r -> r.TrySetResult(Error "closed") |> ignore)

    /// Stop the mailbox: a waiting reader fails, and a served one leaves its node.
    member this.Stop() =
        let waiting =
            lock gate (fun () ->
                stopped <- true
                let r = reader
                reader <- None
                r)

        waiting |> Option.iter (fun r -> r.TrySetResult(Error "closed") |> ignore)

        match network with
        | Some(node, name, _, _) ->
            (try
                node.Unregister name
             with _ ->
                 ())
        | None -> ()

    interface IDisposable with
        member this.Dispose() = this.Stop()

/// Sending to a mailbox on another node.
[<Sealed>]
type MailboxSender(node: Node, address: string, descriptor: string, timeout: int) =
    do
        if timeout <= 0 then
            Fail.raiseWith "Mailbox" "invalid_sender"

    let table, d = Descriptors.fromText descriptor

    /// Send, waiting until the mailbox has the value.
    member _.Send(value: Value) =
        match node.Request(address, "mail", Descriptors.encode d value table, timeout) with
        | 0, _ -> ()
        | 2, _ -> Fail.raiseWith "Mailbox" "closed"
        | status, body -> Fail.raiseWith "Mailbox" (sprintf "remote %d %s" status (Encoding.UTF8.GetString body))

/// Mailboxes, as generated code opens and uses them.
module Mailboxes =
    [<CompiledName("Open")>]
    let openMailbox () = new Mailbox()

    /// A mailbox for a body, stopped after it.
    [<CompiledName("WithMailbox")>]
    let withMailbox (body: Mailbox -> 'a) : 'a =
        use box = new Mailbox()
        body box

    [<CompiledName("Serve")>]
    let serve (node: Node) (name: string) (descriptor: string) = Mailbox.Serve(node, name, descriptor)

    [<CompiledName("Connect")>]
    let connect (node: Node) (address: string) (descriptor: string) (timeout: int) =
        MailboxSender(node, address, descriptor, timeout)
