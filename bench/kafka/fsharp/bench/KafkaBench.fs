/// The Kafka reference model's workload, driven through the generated
/// cluster spec handler of the Broker ability: produce across 100
/// partitions, a consumer group of ten members fetching and committing with
/// a rebalance, then transactions. See bench/README.md.
module KafkaBench

open System
open System.Diagnostics
open LawSpec.Data
open LawSpec.Handlers.LawtwinKafka

/// The topic's partitions, the group's members and records per fetch.
let partitions = 100
/// The consumer group's members.
let members = 10
/// Records per fetch.
let fetchSize = 500

/// A request's value; a refusal ends the run.
let ok (result: Result<'T, KafkaError>) =
    match result with
    | Ok value -> value
    | Error error -> failwithf "refused: %A" error

/// The benchmark topic's partition p.
let tp (p: int) : TopicPartition = { Topic = "bench"; Partition = p }

/// A record with an 8-byte key and a 64-byte value.
let record (i: int64) : Record =
    let key = BitConverter.GetBytes(i) |> Array.rev
    { Key = Some key; Value = Some(Array.create 64 (byte 'x')); Headers = [] }

/// Prints a phase's operations and seconds.
let phase (name: string) (ops: int64) (start: int64) =
    printfn "phase %s %d %.6f" name ops (float (Stopwatch.GetTimestamp() - start) / float Stopwatch.Frequency)

/// Prints the live heap after collecting.
let memory (label: string) =
    for _ in 1..3 do GC.Collect()
    printfn "memory %s %d" label (GC.GetTotalMemory true)

/// The workload, at a scale.
let run (scale: int64) =
    let broker = Cluster()
    let all = Stopwatch.GetTimestamp()
    let mutable total = 0L
    ok (broker.CreateTopicsRequest("bench", partitions))

    let start = Stopwatch.GetTimestamp()
    for i in 0L .. scale - 1L do
        ok (broker.ProduceRequest(tp (int (i % int64 partitions)), None, [ record i ])) |> ignore
    phase "produce" scale start
    total <- total + scale
    memory "after-produce"

    let start = Stopwatch.GetTimestamp()
    let mutable ops = 0L
    let names = [ for m in 0 .. members - 1 -> sprintf "member-%d" m ]
    let mutable generation = 0
    for m in names do
        generation <- ok (broker.JoinGroupRequest("g", m, [ "bench" ]))
        ops <- ops + 1L
    let mutable read = 0L
    for round in 0 .. 1 do
        if round = 1 then
            ok (broker.LeaveGroupRequest("g", List.last names))
            generation <- ok (broker.JoinGroupRequest("g", List.last names, [ "bench" ]))
            ops <- ops + 2L
        for m in names do
            ok (broker.HeartbeatRequest("g", m, generation))
            let assigned = ok (broker.SyncGroupRequest("g", m, generation))
            ops <- ops + 2L
            for p in assigned do
                let mutable position = defaultArg (broker.OffsetFetchRequest("g", p)) 0L
                ops <- ops + 1L
                let mutable reading = true
                while reading do
                    let r = ok (broker.FetchRequest(p, position, fetchSize, ReadUncommitted))
                    ops <- ops + 1L
                    let finish = if round = 0 then r.HighWatermark / 2L else r.HighWatermark
                    if List.isEmpty r.Records || position >= finish then reading <- false
                    else
                        read <- read + int64 (List.length r.Records)
                        position <- r.NextOffset
                        ok (broker.OffsetCommitRequest("g", m, generation, [ { TopicPartition = p; Offset = position } ]))
                        ops <- ops + 1L
    phase "consume" ops start
    total <- total + ops
    printfn "check records-read %d" read

    let start = Stopwatch.GetTimestamp()
    let mutable ops = 0L
    let txns = max 1L (scale / 100L)
    let id = ok (broker.InitProducerIdRequest(Some "tx"))
    ops <- ops + 1L
    let sequences = Array.zeroCreate<int> partitions
    for t in 0L .. txns - 1L do
        let parts = [ int ((2L * t) % int64 partitions); int ((2L * t + 1L) % int64 partitions) ]
        ok (broker.AddPartitionsToTxnRequest("tx", id.ProducerId, id.ProducerEpoch, List.map tp parts))
        for p in parts do
            let tag = { ProducerId = id.ProducerId; ProducerEpoch = id.ProducerEpoch; BaseSequence = sequences.[p] }
            sequences.[p] <- sequences.[p] + 1
            ok (broker.ProduceRequest(tp p, Some tag, [ record t ])) |> ignore
        ok (broker.TxnOffsetCommitRequest("tx", id.ProducerId, id.ProducerEpoch, "g", [ { TopicPartition = tp (List.head parts); Offset = t } ]))
        ok (broker.EndTxnRequest("tx", id.ProducerId, id.ProducerEpoch, true))
        ops <- ops + 5L
    phase "transactions" ops start
    total <- total + ops
    phase "total" total all
    memory "end"
    let r = ok (broker.FetchRequest(tp 0, 0L, 10, ReadCommitted))
    printfn "check committed-hw %d" r.HighWatermark

    // The embedding API: a refusal as a value, and the state kept and put back.
    match broker.ProduceRequest({ Topic = "missing"; Partition = 0 }, None, [ record 0L ]) with
    | Error error -> printfn "check refused %A" error
    | Ok _ -> printfn "check refused nothing"
    let snapshot = broker.State
    ok (broker.ProduceRequest(tp 0, None, [ record 0L ])) |> ignore
    broker.State <- snapshot
    let after = ok (broker.FetchRequest(tp 0, 0L, 10, ReadCommitted))
    printfn "check restored %b" (after.HighWatermark = r.HighWatermark)

/// Runs the workload on a thread with a deep stack.
[<EntryPoint>]
let main argv =
    let scale = if argv.Length > 0 then int64 argv.[0] else 1_000_000L
    // A deep stack, as the other drivers use: persistent structures recurse.
    let worker = Threading.Thread((fun () -> run scale), 1 <<< 30)
    worker.Start()
    worker.Join()
    0
