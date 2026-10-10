"""The Kafka reference model's workload, driven through the generated
cluster spec handler of the Broker ability: produce across 100 partitions, a
consumer group of ten members fetching and committing with a rebalance, then
transactions. See bench/README.md."""
import gc
import sys
import time
import tracemalloc

sys.path.insert(0, "src")
sys.setrecursionlimit(1_000_000)

import lawspec_data as data  # noqa: E402
import lawspec_schema as schema  # noqa: E402
from lawspec_abilities.lawtwin.kafka import Cluster  # noqa: E402

PARTITIONS = 100
MEMBERS = 10
FETCH_MAX = 500


def tp(p):
    return data.TopicPartition("bench", p)


def record(i):
    return data.Record(schema.Just(i.to_bytes(8, "big")), schema.Just(b"x" * 64), [])


def phase(name, ops, start):
    print(f"phase {name} {ops} {time.perf_counter() - start:.6f}", flush=True)


def memory(label):
    gc.collect()
    if tracemalloc.is_tracing():
        print(f"memory {label} {tracemalloc.get_traced_memory()[0]}", flush=True)


def main():
    scale = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
    if "--memory" in sys.argv:
        tracemalloc.start()
    broker = Cluster()
    everything = time.perf_counter()
    total = 0
    broker.createTopicsRequest("bench", PARTITIONS)

    start = time.perf_counter()
    nothing = schema.Nothing()
    for i in range(scale):
        broker.produceRequest(tp(i % PARTITIONS), nothing, [record(i)])
    phase("produce", scale, start)
    total += scale
    memory("after-produce")

    start = time.perf_counter()
    ops = 0
    names = [f"member-{m}" for m in range(MEMBERS)]
    generation = 0
    for m in names:
        generation = broker.joinGroupRequest("g", m, ["bench"])
        ops += 1
    read = 0
    uncommitted = data.IsolationLevelReadUncommitted()
    for round_ in range(2):
        if round_ == 1:
            broker.leaveGroupRequest("g", names[-1])
            generation = broker.joinGroupRequest("g", names[-1], ["bench"])
            ops += 2
        for m in names:
            broker.heartbeatRequest("g", m, generation)
            assigned = broker.syncGroupRequest("g", m, generation)
            ops += 2
            for p in assigned:
                position = getattr(broker.offsetFetchRequest("g", p), "value", 0)
                ops += 1
                while True:
                    r = broker.fetchRequest(p, position, FETCH_MAX, uncommitted)
                    ops += 1
                    end = r.highWatermark if round_ == 1 else r.highWatermark // 2
                    if not r.records or position >= end:
                        break
                    read += len(r.records)
                    position = r.nextOffset
                    broker.offsetCommitRequest("g", m, generation, [data.OffsetEntry(p, position)])
                    ops += 1
    phase("consume", ops, start)
    total += ops
    print(f"check records-read {read}")

    start = time.perf_counter()
    ops = 0
    txns = max(1, scale // 100)
    pid = broker.initProducerIdRequest(schema.Just("tx"))
    ops += 1
    sequences = [0] * PARTITIONS
    for t in range(txns):
        parts = [(2 * t) % PARTITIONS, (2 * t + 1) % PARTITIONS]
        broker.addPartitionsToTxnRequest("tx", pid.producerId, pid.producerEpoch, [tp(parts[0]), tp(parts[1])])
        for p in parts:
            tag = data.ProducerTag(pid.producerId, pid.producerEpoch, sequences[p])
            sequences[p] += 1
            broker.produceRequest(tp(p), schema.Just(tag), [record(t)])
        broker.txnOffsetCommitRequest("tx", pid.producerId, pid.producerEpoch, "g", [data.OffsetEntry(tp(parts[0]), t)])
        broker.endTxnRequest("tx", pid.producerId, pid.producerEpoch, True)
        ops += 5
    phase("transactions", ops, start)
    total += ops
    phase("total", total, everything)
    memory("end")
    r = broker.fetchRequest(tp(0), 0, 10, data.IsolationLevelReadCommitted())
    print(f"check committed-hw {r.highWatermark}")


if __name__ == "__main__":
    main()
