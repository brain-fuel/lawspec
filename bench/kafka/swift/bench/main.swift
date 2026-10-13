// The Kafka reference model's workload, driven through the generated cluster
// spec handler of the Broker ability: produce across 100 partitions, a
// consumer group of ten members fetching and committing with a rebalance,
// then transactions. See bench/README.md.
import App
import Darwin
import Foundation
import LawSpecRuntime

/// The topic's partitions.
let partitions = 100
/// The consumer group's members.
let members = 10
/// Records per fetch.
let fetchSize: Int32 = 500

/// A request's value; a refusal ends the run.
func ok<T>(_ request: () throws(KafkaError) -> T) -> T {
    do {
        return try request()
    } catch {
        fatalError("refused: \(error)")
    }
}

/// The benchmark topic's partition p.
func tp(_ p: Int) -> TopicPartition { TopicPartition(topic: "bench", partition: Int32(p)) }

/// A record with an 8-byte key and a 64-byte value.
func record(_ i: Int64) -> Record {
    let key = withUnsafeBytes(of: i.bigEndian) { Array($0) }
    return Record(key: key, value: [UInt8](repeating: UInt8(ascii: "x"), count: 64), headers: [])
}

/// Now, in seconds on a monotonic clock.
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// Prints a phase's operations and seconds.
func phase(_ name: String, _ ops: Int64, _ start: Double) {
    print("phase \(name) \(ops) \(String(format: "%.6f", now() - start))")
}

/// Prints the process's physical footprint: Swift frees by reference
/// counting, so there is no collector to run first.
func memory(_ label: String) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    print("memory \(label) \(result == KERN_SUCCESS ? info.phys_footprint : 0)")
}

/// The workload, at a scale.
func run(_ scale: Int64) {
    let broker = LawSpec.Handlers.LawtwinKafka.Cluster()
    let all = now()
    var total: Int64 = 0
    ok { () throws(KafkaError) in try broker.createTopicsRequest("bench", Int32(partitions)) }

    var start = now()
    for i in 0..<scale {
        _ = ok { () throws(KafkaError) in try broker.produceRequest(tp(Int(i % Int64(partitions))), nil, [record(i)]) }
    }
    phase("produce", scale, start)
    total += scale
    memory("after-produce")

    start = now()
    var ops: Int64 = 0
    let names = (0..<members).map { "member-\($0)" }
    var generation: Int32 = 0
    for m in names {
        generation = ok { () throws(KafkaError) in try broker.joinGroupRequest("g", m, ["bench"]) }
        ops += 1
    }
    var read: Int64 = 0
    for round in 0...1 {
        if round == 1 {
            ok { () throws(KafkaError) in try broker.leaveGroupRequest("g", names.last!) }
            generation = ok { () throws(KafkaError) in try broker.joinGroupRequest("g", names.last!, ["bench"]) }
            ops += 2
        }
        for m in names {
            let current = generation
            ok { () throws(KafkaError) in try broker.heartbeatRequest("g", m, current) }
            let assigned = ok { () throws(KafkaError) in try broker.syncGroupRequest("g", m, current) }
            ops += 2
            for p in assigned {
                var position = broker.offsetFetchRequest("g", p) ?? 0
                ops += 1
                while true {
                    let from = position
                    let r = ok { () throws(KafkaError) in try broker.fetchRequest(p, from, fetchSize, .readUncommitted) }
                    ops += 1
                    let finish = round == 0 ? r.highWatermark / 2 : r.highWatermark
                    if r.records.isEmpty || position >= finish { break }
                    read += Int64(r.records.count)
                    position = r.nextOffset
                    let offset = position
                    ok { () throws(KafkaError) in
                        try broker.offsetCommitRequest("g", m, current, [OffsetEntry(topicPartition: p, offset: offset)])
                    }
                    ops += 1
                }
            }
        }
    }
    phase("consume", ops, start)
    total += ops
    print("check records-read \(read)")

    start = now()
    ops = 0
    let txns = max(1, scale / 100)
    let id = ok { () throws(KafkaError) in try broker.initProducerIdRequest("tx") }
    ops += 1
    var sequences = [Int32](repeating: 0, count: partitions)
    for t in 0..<txns {
        let parts = [Int((2 * t) % Int64(partitions)), Int((2 * t + 1) % Int64(partitions))]
        ok { () throws(KafkaError) in
            try broker.addPartitionsToTxnRequest("tx", id.producerId, id.producerEpoch, PersistentList(parts.map(tp)))
        }
        for p in parts {
            let tag = ProducerTag(producerId: id.producerId, producerEpoch: id.producerEpoch, baseSequence: sequences[p])
            sequences[p] += 1
            _ = ok { () throws(KafkaError) in try broker.produceRequest(tp(p), tag, [record(t)]) }
        }
        ok { () throws(KafkaError) in
            try broker.txnOffsetCommitRequest("tx", id.producerId, id.producerEpoch, "g",
                [OffsetEntry(topicPartition: tp(parts[0]), offset: t)])
        }
        ok { () throws(KafkaError) in try broker.endTxnRequest("tx", id.producerId, id.producerEpoch, true) }
        ops += 5
    }
    phase("transactions", ops, start)
    total += ops
    phase("total", total, all)
    memory("end")
    let r = ok { () throws(KafkaError) in try broker.fetchRequest(tp(0), 0, 10, .readCommitted) }
    print("check committed-hw \(r.highWatermark)")

    // The embedding API: a refusal as a typed throw, and the state kept and put back.
    do {
        _ = try broker.produceRequest(TopicPartition(topic: "missing", partition: 0), nil, [record(0)])
        print("check refused nothing")
    } catch {
        print("check refused \(error)")
    }
    let snapshot = broker.state
    _ = ok { () throws(KafkaError) in try broker.produceRequest(tp(0), nil, [record(0)]) }
    broker.state = snapshot
    let after = ok { () throws(KafkaError) in try broker.fetchRequest(tp(0), 0, 10, .readCommitted) }
    print("check restored \(after.highWatermark == r.highWatermark)")
}

// Runs the workload on a thread with a deep stack, as the other drivers do:
// persistent structures recurse.
let scale = CommandLine.arguments.count > 1 ? Int64(CommandLine.arguments[1])! : 1_000_000
let done = DispatchSemaphore(value: 0)
let worker = Thread {
    run(scale)
    done.signal()
}
worker.stackSize = 1 << 30
worker.start()
done.wait()
