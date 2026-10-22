// The Kafka reference model's workload, driven through the generated
// cluster spec handler of the Broker ability: produce across 100
// partitions, a consumer group of ten members fetching and committing with a
// rebalance, then transactions. See bench/README.md.
package bench

import lawspec.abilities.lawtwin.Kafka
import lawspec.data.FetchResult
import lawspec.data.IsolationLevel
import lawspec.data.OffsetEntry
import lawspec.data.ProducerTag
import lawspec.data.Record
import lawspec.data.TopicPartition
import lawspec.runtime.LawSpecRuntime

const val PARTITIONS = 100
const val MEMBERS = 10
const val FETCH = 500

fun tp(p: Int) = TopicPartition("bench", p)

fun record(i: Long): Record {
    val key = java.nio.ByteBuffer.allocate(8).putLong(i).array()
    val value = ByteArray(64) { 'x'.code.toByte() }
    return Record(LawSpecRuntime.Present(key), LawSpecRuntime.Present(value), listOf())
}

fun phase(name: String, ops: Long, start: Long) =
    println("phase $name $ops ${"%.6f".format((System.nanoTime() - start) / 1e9)}")

fun memory(label: String) {
    repeat(3) { System.gc() }
    val r = Runtime.getRuntime()
    println("memory $label ${r.totalMemory() - r.freeMemory()}")
}

fun main(args: Array<String>) {
    val scale = if (args.isNotEmpty()) args[0].toLong() else 1_000_000L
    val worker = Thread(null, { run(scale) }, "bench", 1L shl 30)
    worker.start()
    worker.join()
}

fun run(scale: Long) {
    val broker = Kafka.Cluster()
    val all = System.nanoTime()
    var total = 0L
    broker.createTopicsRequest("bench", PARTITIONS)

    var start = System.nanoTime()
    for (i in 0 until scale) {
        broker.produceRequest(tp((i % PARTITIONS).toInt()), LawSpecRuntime.Absent(), listOf(record(i)))
    }
    phase("produce", scale, start)
    total += scale
    memory("after-produce")

    start = System.nanoTime()
    var ops = 0L
    val members = (0 until MEMBERS).map { "member-$it" }
    var generation = 0
    for (m in members) {
        generation = broker.joinGroupRequest("g", m, listOf("bench"))
        ops++
    }
    var read = 0L
    for (round in 0 until 2) {
        if (round == 1) {
            broker.leaveGroupRequest("g", members.last())
            generation = broker.joinGroupRequest("g", members.last(), listOf("bench"))
            ops += 2
        }
        for (m in members) {
            broker.heartbeatRequest("g", m, generation)
            val assigned = broker.syncGroupRequest("g", m, generation)
            ops += 2
            for (p in assigned) {
                val committed = broker.offsetFetchRequest("g", p)
                var position = if (committed is LawSpecRuntime.Present<Long>) committed.value() else 0L
                ops++
                while (true) {
                    val r: FetchResult = broker.fetchRequest(p, position, FETCH, IsolationLevel.ReadUncommitted)
                    ops++
                    val end = if (round == 0) r.highWatermark / 2 else r.highWatermark
                    if (r.records.isEmpty() || position >= end) break
                    read += r.records.size
                    position = r.nextOffset
                    broker.offsetCommitRequest("g", m, generation, listOf(OffsetEntry(p, position)))
                    ops++
                }
            }
        }
    }
    phase("consume", ops, start)
    total += ops
    println("check records-read $read")

    start = System.nanoTime()
    ops = 0
    val txns = maxOf(1L, scale / 100)
    val id = broker.initProducerIdRequest(LawSpecRuntime.Present("tx"))
    ops++
    val sequences = IntArray(PARTITIONS)
    for (t in 0 until txns) {
        val parts = intArrayOf(((2 * t) % PARTITIONS).toInt(), ((2 * t + 1) % PARTITIONS).toInt())
        broker.addPartitionsToTxnRequest("tx", id.producerId, id.producerEpoch, parts.map { tp(it) })
        for (p in parts) {
            val tag = ProducerTag(id.producerId, id.producerEpoch, sequences[p]++)
            broker.produceRequest(tp(p), LawSpecRuntime.Present(tag), listOf(record(t)))
        }
        broker.txnOffsetCommitRequest("tx", id.producerId, id.producerEpoch, "g", listOf(OffsetEntry(tp(parts[0]), t)))
        broker.endTxnRequest("tx", id.producerId, id.producerEpoch, true)
        ops += 5
    }
    phase("transactions", ops, start)
    total += ops
    phase("total", total, all)
    memory("end")
    val r = broker.fetchRequest(tp(0), 0L, 10, IsolationLevel.ReadCommitted)
    println("check committed-hw ${r.highWatermark}")

    // The embedding API: a refusal as a value, and the state kept and put back.
    val refused = broker.tryProduceRequest(TopicPartition("missing", 0), LawSpecRuntime.Absent(), listOf(record(0)))
    println("check refused ${if (refused.failed()) refused.failure()::class.simpleName else "nothing"}")
    val snapshot = broker.typedState()
    broker.produceRequest(tp(0), LawSpecRuntime.Absent(), listOf(record(0)))
    broker.setTypedState(snapshot)
    val after = broker.fetchRequest(tp(0), 0L, 10, IsolationLevel.ReadCommitted)
    println("check restored ${after.highWatermark == r.highWatermark}")
    val nativeState = broker::state
}
