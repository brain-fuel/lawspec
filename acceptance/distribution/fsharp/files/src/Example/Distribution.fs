// User-owned LawSpec adapter: the wire encoding, and nodes talking over
// in-memory, TCP and HTTP transports.
module Example.Distribution

open System
open System.Numerics
open System.Text
open System.Threading.Tasks
open LawSpec.Runtime
open LawSpec.Data
open LawSpec.Actors
open LawSpec.Mailboxes
open LawSpec.Sessions

let encoded (text: string) (seed: uint64) (size: int) (count: int) : string list =
    Network.wireEncoded text (BigInteger seed) size count

let roundTrips (text: string) (seed: uint64) (size: int) (count: int) : bool =
    Network.wireRoundTrips text (BigInteger seed) size count

let private memory (seed: int) loss duplicate delay record =
    Network.memory (Network.memoryOptions (BigInteger(seed &&& 0xFFFF)) loss duplicate delay record)

let private node transport = Network.openNode transport (Network.options ())

let private local () = node (Network.tcp "127.0.0.1" 0)

let remoteShifted (x: int) : Task<int64> =
    Task.Run(fun () ->
        use network = memory x 0.2 0.2 0.0 false
        use here = node (Network.memoryTransport network "here")
        use there = node (Network.memoryTransport network "there")
        LawSpec.RemoteDefinitions.serve there |> ignore
        match LawSpec.RemoteDefinitions.evaluate here there.Address "example.distribution::shifted" [ Value.Int(BigInteger x) ] with
        | Value.Int n -> int64 n
        | other -> failwithf "unexpected %A" other)

let openTally () : Tally = { Count = 0L }

let add (tally: Tally) (n: byte) : Pair<int64, Tally> =
    let after = tally.Count + int64 n
    { First = after; Second = { Count = after } }

let private tallyHandlers: TallyActorHandlers = { OpenTally = openTally; Add = add }

let remoteAdds (n: byte) : Task<int64> =
    Task.Run(fun () ->
        use server = local ()
        use client = local ()
        let actor = TallyActor.Start tallyHandlers
        try
            let address = actor.Serve(server, "tally")
            let tally = TallyActor.Connect(client, address)
            tally.Add n |> ignore
            tally.Add n
        finally
            actor.Stop())

let remoteDoubling (x: int) : Task<int64> =
    Task.Run(fun () ->
        use server = node (Network.http "127.0.0.1" 0)
        use client = node (Network.http "127.0.0.1" 0)
        let first = Doubling.listen server "doubling"
        let second = Doubling.dial client (server.Address + "/doubling")
        let worker =
            Task.Run(fun () ->
                let got, next = second.Receive()
                next.Send(2L * int64 got) |> ignore)
        let reply, _ = (first.Send x).Receive()
        worker.Wait()
        reply)

let remoteLedger (x: int) : Task<int64> =
    Task.Run(fun () ->
        use here = local ()
        use there = local ()
        let ledger = LedgerMailbox.Serve(there, "ledger")
        let sender = LedgerMailbox.Connect(here, there.Address + "/ledger")
        sender.Send(int64 x)
        sender.Send(int64 x)
        let timeout = TimeSpan.FromSeconds 5.0
        let total = ledger.Receive timeout + ledger.Receive timeout
        // Nothing more comes, so receiving within a moment gives nothing.
        if (ledger.ReceiveWithin(TimeSpan.FromMilliseconds 20.0)).IsSome then -1L else total)

let remoteHandoff (x: int) : Task<int64> =
    Task.Run(fun () ->
        use here = local ()
        use there = local ()
        // A local conversation on this node; its first end goes to the other.
        let first, second = Doubling.channel ()
        let worker =
            Task.Run(fun () ->
                let got, next = second.Receive()
                next.Send(2L * int64 got) |> ignore)
        let giving = Handoff.listen here "handoff"
        let taking = Handoff.dial there (here.Address + "/handoff")
        giving.Send first |> ignore
        let moved, _ = taking.Receive()
        let reply, _ = (moved.Send x).Receive()
        worker.Wait()
        reply)

let remoteHandoffOnward (x: int) : Task<int64> =
    Task.Run(fun () ->
        use network = memory x 0.1 0.1 0.005 false
        let a = node (Network.memoryTransport network "a")
        let b = node (Network.memoryTransport network "b")
        use c = node (Network.memoryTransport network "c")
        use d = node (Network.memoryTransport network "d")
        try
            // A conversation between A and C, which sends at once; A's end
            // moves to B, then to D, and answers from there.
            let first = Answering.listen a "answering"
            let second = (Answering.dial c (a.Address + "/answering")).Send x
            let toB = Passing.listen a "to-b"
            let atB = Passing.dial b (a.Address + "/to-b")
            toB.Send first |> ignore
            let moved, _ = atB.Receive()
            let toD = Passing.listen b "to-d"
            let atD = Passing.dial d (b.Address + "/to-d")
            toD.Send moved |> ignore
            let answering, _ = atD.Receive()
            // The end no longer needs A or B.
            a.Close()
            b.Close()
            let got, next = answering.Receive()
            next.Send(2L * int64 got) |> ignore
            fst (second.Receive())
        finally
            a.Close()
            b.Close())

let private contains (haystack: byte[]) (needle: byte[]) =
    Seq.exists (fun i -> haystack.AsSpan(i, needle.Length).SequenceEqual(ReadOnlySpan needle)) [ 0 .. haystack.Length - needle.Length ]

// A definition evaluated on another node: its request names the definition's
// content hash, which shows on the wire only in the clear.
let sealedOnTheWire (x: int) : Task<bool> =
    Task.Run(fun () ->
        let name = "example.distribution::shifted"
        let digest = Encoding.UTF8.GetBytes(LawSpec.RemoteDefinitions.digest name)
        let seen =
            [ for insecure in [ false; true ] ->
                  use network = memory x 0.0 0.0 0.0 true
                  let transport = if insecure then Network.insecureMemoryTransportForTests else Network.memoryTransport
                  use here = node (transport network "here")
                  use there = node (transport network "there")
                  LawSpec.RemoteDefinitions.serve there |> ignore
                  match LawSpec.RemoteDefinitions.evaluate here there.Address name [ Value.Int(BigInteger x) ] with
                  | Value.Int n when n = BigInteger(int64 x + 1000L) ->
                      Some(Network.recorded network |> List.exists (fun frame -> contains frame digest))
                  | _ -> None ]
        seen = [ Some false; Some true ])

let handshakeAgrees (text: string) : bool =
    match text.Split ' ' with
    | [| a; b; c; d; e; f; g; h; i; j; k; l; m |] -> Network.handshakeVector a b c d e f g h i j k l m
    | _ -> false
