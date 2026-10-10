namespace LawSpec.Runtime

open System
open System.Threading
open System.Threading.Tasks
open System.Numerics

/// What happened to a frame sent on a memory network.
type MemoryEvent =
    { Source: string
      To: string
      Frame: byte[]
      Outcome: string
      /// The delay slots of each copy (two when the frame was duplicated).
      DelaySlots: int list }

/// The options of an in-memory network: a seed for its faults, the chances
/// of losing and of duplicating a frame, the most a frame is delayed (in
/// seconds), and whether it records every frame.
type MemoryOptions =
    { Seed: BigInteger
      Loss: float
      Duplicate: float
      Delay: float
      Record: bool }

/// An owned in-memory packet transport with seeded loss, duplication and
/// delay. Frames can overtake each other; reliability belongs to the node and
/// the channel protocol above it, and no application code runs here.
/// ref:DEC-distribution-canonical-wire ref:DEC-portable-seeded-generation
[<Sealed; AllowNullLiteral>]
type MemoryNetwork(options: MemoryOptions) =
    do
        let valid condition reason = if not condition then Fail.raiseWith "MemoryNetwork" reason
        valid (options.Loss >= 0.0 && options.Loss <= 1.0) "invalid loss probability"
        valid (options.Duplicate >= 0.0 && options.Duplicate <= 1.0) "invalid duplicate probability"
        valid (options.Delay >= 0.0 && options.Delay <= 4294967.0) "invalid delay"
    let gate = obj ()
    let mutable random = Random.seed options.Seed
    let mutable generation = 0L
    // Each registered address: its receiver and the generation it was registered at.
    let nodes = Collections.Generic.Dictionary<string, (string -> byte[] -> unit) * int64>()
    let mutable groups: string list list option = None
    let trace = ResizeArray<MemoryEvent>()
    let mutable closed = false
    let cancel = new CancellationTokenSource()

    static member DefaultOptions =
        { Seed = BigInteger.Zero; Loss = 0.0; Duplicate = 0.0; Delay = 0.0; Record = false }

    /// mem://name for a bare name.
    static member AddressOf(name: string) =
        if name.StartsWith "mem://" then name
        elif String.IsNullOrEmpty name then Fail.raiseWith "MemoryNetwork" "an empty node name"
        else "mem://" + name

    member private this.Chance(probability: float) =
        if probability <= 0.0 then false
        else
            let draw, next = Random.below (BigInteger(1 <<< 30)) random
            random <- next
            float draw < probability * float (1 <<< 30)

    member private this.Remember(event: MemoryEvent) = if options.Record then trace.Add event

    /// Register a receiver at an address.
    member this.Register(address: string, receiver: string -> byte[] -> unit) : Result<unit, string> =
        let address = MemoryNetwork.AddressOf address
        lock gate (fun () ->
            if closed then Error "network_closed"
            elif nodes.ContainsKey address then Error "already_registered"
            else
                generation <- generation + 1L
                nodes.[address] <- (receiver, generation)
                Ok())

    member this.Unregister(address: string) =
        let address = MemoryNetwork.AddressOf address
        lock gate (fun () -> nodes.Remove address |> ignore)

    /// Send bytes from one registered address to another.
    member this.Send(source: string, destination: string, bytes: byte[]) : Result<unit, string> =
        let source = MemoryNetwork.AddressOf source
        let destination = MemoryNetwork.AddressOf destination
        let deliveries =
            lock gate (fun () ->
                let event = { Source = source; To = destination; Frame = bytes; Outcome = ""; DelaySlots = [] }
                if closed || not (nodes.ContainsKey source) then Error "not_node_owner"
                else
                    match nodes.TryGetValue destination with
                    | false, _ ->
                        this.Remember { event with Outcome = "unreachable" }
                        Error("unreachable " + destination)
                    | true, (_, registered) ->
                        let reachable =
                            match groups with
                            | None -> true
                            | Some gs -> gs |> List.exists (fun g -> List.contains source g && List.contains destination g)
                        if not reachable then
                            this.Remember { event with Outcome = "partitioned" }
                            Ok []
                        elif this.Chance options.Loss then
                            this.Remember { event with Outcome = "lost" }
                            Ok []
                        else
                            let copies = if this.Chance options.Duplicate then 2 else 1
                            let slots =
                                [ for _ in 1 .. copies ->
                                      let slot, next = Random.below (BigInteger 1001) random
                                      random <- next
                                      int slot ]
                            this.Remember { event with Outcome = "sent"; DelaySlots = slots }
                            Ok [ for slot in slots -> int (ceil (float slot * options.Delay)), registered ])
        match deliveries with
        | Error e -> Error e
        | Ok copies ->
            for delay, registered in copies do
                let deliver () =
                    let receiver =
                        lock gate (fun () ->
                            match nodes.TryGetValue destination with
                            | true, (r, g) when g = registered && not closed -> Some r
                            | _ -> None)
                    match receiver with
                    | Some r -> (try r source bytes with _ -> ())
                    | None -> ()
                if delay <= 0 then ThreadPool.QueueUserWorkItem(fun _ -> deliver ()) |> ignore
                else
                    Task.Delay(delay, cancel.Token).ContinueWith(fun (t: Task) -> if not t.IsCanceled then deliver ())
                    |> ignore
            Ok()

    /// Only nodes in one group reach each other until healed.
    member this.Partition(groups': string list list) =
        lock gate (fun () -> groups <- Some(groups' |> List.map (List.map MemoryNetwork.AddressOf)))

    member this.Heal() = lock gate (fun () -> groups <- None)

    /// Every frame sent, in order, when recording.
    member this.Recorded() = lock gate (fun () -> trace |> Seq.map (fun e -> e.Frame) |> List.ofSeq)

    member this.Trace() = lock gate (fun () -> List.ofSeq trace)

    member this.Close() =
        lock gate (fun () ->
            closed <- true
            nodes.Clear())
        cancel.Cancel()

    interface IDisposable with
        member this.Dispose() = this.Close()
