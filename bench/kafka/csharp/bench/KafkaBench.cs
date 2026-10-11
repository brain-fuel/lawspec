// The Kafka reference model's workload, driven through the generated cluster
// spec handler of the Broker ability: produce across 100 partitions, a
// consumer group of ten members fetching and committing with a rebalance,
// then transactions. See bench/README.md.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using Microsoft.FSharp.Collections;
using Microsoft.FSharp.Core;
using LawSpec.CSharp;
using LawSpec.Data;
using LawSpec.Handlers.LawtwinKafka;

public static class KafkaBench
{
    const int Partitions = 100;
    const int Members = 10;
    const int Fetch = 500;

    static T Ok<T>(FSharpResult<T, KafkaError> result) =>
        result.IsOk ? result.ResultValue : throw new InvalidOperationException($"refused: {result.ErrorValue}");

    static TopicPartition Tp(int p) => new("bench", p);

    static Record Record(long i)
    {
        var key = BitConverter.GetBytes(i);
        Array.Reverse(key);
        var value = Enumerable.Repeat((byte)'x', 64).ToArray();
        return new Record(Maybe.Of(key), Maybe.Of(value), FSharpList<Header>.Empty);
    }

    static void Phase(string name, long ops, long start) =>
        Console.WriteLine($"phase {name} {ops} {(Stopwatch.GetTimestamp() - start) / (double)Stopwatch.Frequency:F6}");

    static void Memory(string label)
    {
        for (var i = 0; i < 3; i++) GC.Collect();
        Console.WriteLine($"memory {label} {GC.GetTotalMemory(true)}");
    }

    public static void Main(string[] args)
    {
        var scale = args.Length > 0 ? long.Parse(args[0]) : 1_000_000L;
        // A deep stack, as the other drivers use: persistent structures recurse.
        var worker = new Thread(() => Run(scale), 1 << 30);
        worker.Start();
        worker.Join();
    }

    static void Run(long scale)
    {
        var broker = new Cluster();
        var all = Stopwatch.GetTimestamp();
        long total = 0;
        broker.CreateTopicsRequest("bench", Partitions);

        var start = Stopwatch.GetTimestamp();
        for (long i = 0; i < scale; i++)
            Ok(broker.ProduceRequest(Tp((int)(i % Partitions)), Maybe.Nothing<ProducerTag>(), Fn.List(Record(i))));
        Phase("produce", scale, start);
        total += scale;
        Memory("after-produce");

        start = Stopwatch.GetTimestamp();
        long ops = 0;
        var members = Enumerable.Range(0, Members).Select(m => $"member-{m}").ToList();
        var topics = Fn.List("bench");
        var generation = 0;
        foreach (var m in members)
        {
            generation = Ok(broker.JoinGroupRequest("g", m, topics));
            ops++;
        }
        long read = 0;
        for (var round = 0; round < 2; round++)
        {
            if (round == 1)
            {
                broker.LeaveGroupRequest("g", members[Members - 1]);
                generation = Ok(broker.JoinGroupRequest("g", members[Members - 1], topics));
                ops += 2;
            }
            foreach (var m in members)
            {
                broker.HeartbeatRequest("g", m, generation);
                var assigned = Ok(broker.SyncGroupRequest("g", m, generation));
                ops += 2;
                foreach (var p in assigned)
                {
                    var position = broker.OffsetFetchRequest("g", p).GetOrElse(0L);
                    ops++;
                    while (true)
                    {
                        var r = Ok(broker.FetchRequest(p, position, Fetch, IsolationLevel.ReadUncommitted));
                        ops++;
                        var end = round == 0 ? r.HighWatermark / 2 : r.HighWatermark;
                        if (r.Records.IsEmpty || position >= end) break;
                        read += r.Records.Length;
                        position = r.NextOffset;
                        broker.OffsetCommitRequest("g", m, generation, Fn.List(new OffsetEntry(p, position)));
                        ops++;
                    }
                }
            }
        }
        Phase("consume", ops, start);
        total += ops;
        Console.WriteLine($"check records-read {read}");

        start = Stopwatch.GetTimestamp();
        ops = 0;
        var txns = Math.Max(1, scale / 100);
        var id = Ok(broker.InitProducerIdRequest(Maybe.Of("tx")));
        ops++;
        var sequences = new int[Partitions];
        for (long t = 0; t < txns; t++)
        {
            int[] parts = { (int)((2 * t) % Partitions), (int)((2 * t + 1) % Partitions) };
            broker.AddPartitionsToTxnRequest("tx", id.ProducerId, id.ProducerEpoch, Fn.List(Tp(parts[0]), Tp(parts[1])));
            foreach (var p in parts)
            {
                var tag = new ProducerTag(id.ProducerId, id.ProducerEpoch, sequences[p]++);
                Ok(broker.ProduceRequest(Tp(p), Maybe.Of(tag), Fn.List(Record(t))));
            }
            broker.TxnOffsetCommitRequest("tx", id.ProducerId, id.ProducerEpoch, "g", Fn.List(new OffsetEntry(Tp(parts[0]), t)));
            broker.EndTxnRequest("tx", id.ProducerId, id.ProducerEpoch, true);
            ops += 5;
        }
        Phase("transactions", ops, start);
        total += ops;
        Phase("total", total, all);
        Memory("end");
        var committed = Ok(broker.FetchRequest(Tp(0), 0L, 10, IsolationLevel.ReadCommitted));
        Console.WriteLine($"check committed-hw {committed.HighWatermark}");

        // The embedding API: a refusal as a value, and the state kept and put back.
        var refused = broker.ProduceRequest(new TopicPartition("missing", 0), Maybe.Nothing<ProducerTag>(), Fn.List(Record(0)));
        Console.WriteLine($"check refused {(refused.IsError ? refused.ErrorValue.ToString() : "nothing")}");
        var snapshot = broker.State;
        Ok(broker.ProduceRequest(Tp(0), Maybe.Nothing<ProducerTag>(), Fn.List(Record(0))));
        broker.State = snapshot;
        var after = Ok(broker.FetchRequest(Tp(0), 0L, 10, IsolationLevel.ReadCommitted));
        Console.WriteLine($"check restored {after.HighWatermark == committed.HighWatermark}");
    }
}
