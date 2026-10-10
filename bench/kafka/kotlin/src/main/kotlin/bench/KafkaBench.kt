// The Kafka reference model's workload, driven through the generated
// reference spec handler of the Broker ability: produce across 100
// partitions, a consumer group of ten members fetching and committing with a
// rebalance, then transactions. See bench/README.md.
package bench

import lawspec.abilities.lawtwin.kafka.Contract
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
    return Record(LawSpecRuntime.Just(key), LawSpecRuntime.Just(value), listOf())
}

fun <A, B> right(e: LawSpecRuntime.Either<A, B>, what: String): B = when (e) {
    is LawSpecRuntime.Right<A, B> -> e.value()
    else -> throw IllegalStateException("$what: ${(e as LawSpecRuntime.Left<A, B>).value()}")
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
    val broker = Contract.Reference()
    val all = System.nanoTime()
    var total = 0L
    right(broker.createTopicsRequest("bench", PARTITIONS), "create topic")

    var start = System.nanoTime()
    for (i in 0 until scale) {
        right(broker.produceRequest(tp((i % PARTITIONS).toInt()), LawSpecRuntime.Nothing(), listOf(record(i))), "produce")
    }
    phase("produce", scale, start)
    total += scale
    memory("after-produce")

    start = System.nanoTime()
    var ops = 0L
    val members = (0 until MEMBERS).map { "member-$it" }
    var generation = 0
    for (m in members) {
        generation = right(broker.joinGroupRequest("g", m, listOf("bench")), "join")
        ops++
    }
    var read = 0L
    for (round in 0 until 2) {
        if (round == 1) {
            right(broker.leaveGroupRequest("g", members.last()), "leave")
            generation = right(broker.joinGroupRequest("g", members.last(), listOf("bench")), "rejoin")
            ops += 2
        }
        for (m in members) {
            right(broker.heartbeatRequest("g", m, generation), "heartbeat")
            val assigned = right(broker.syncGroupRequest("g", m, generation), "sync")
            ops += 2
            for (p in assigned) {
                val committed = broker.offsetFetchRequest("g", p)
                var position = if (committed is LawSpecRuntime.Just<Long>) committed.value() else 0L
                ops++
                while (true) {
                    val r: FetchResult = right(broker.fetchRequest(p, position, FETCH, IsolationLevel.ReadUncommitted), "fetch")
                    ops++
                    val end = if (round == 0) r.highWatermark / 2 else r.highWatermark
                    if (r.records.isEmpty() || position >= end) break
                    read += r.records.size
                    position = r.nextOffset
                    right(broker.offsetCommitRequest("g", m, generation, listOf(OffsetEntry(p, position))), "commit")
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
    val id = right(broker.initProducerIdRequest(LawSpecRuntime.Just("tx")), "init producer")
    ops++
    val sequences = IntArray(PARTITIONS)
    for (t in 0 until txns) {
        val parts = intArrayOf(((2 * t) % PARTITIONS).toInt(), ((2 * t + 1) % PARTITIONS).toInt())
        right(broker.addPartitionsToTxnRequest("tx", id.producerId, id.producerEpoch, parts.map { tp(it) }), "add partitions")
        for (p in parts) {
            val tag = ProducerTag(id.producerId, id.producerEpoch, sequences[p]++)
            right(broker.produceRequest(tp(p), LawSpecRuntime.Just(tag), listOf(record(t))), "transactional produce")
        }
        right(broker.txnOffsetCommitRequest("tx", id.producerId, id.producerEpoch, "g", listOf(OffsetEntry(tp(parts[0]), t))), "txn offsets")
        right(broker.endTxnRequest("tx", id.producerId, id.producerEpoch, true), "commit")
        ops += 5
    }
    phase("transactions", ops, start)
    total += ops
    phase("total", total, all)
    memory("end")
    val r = right(broker.fetchRequest(tp(0), 0L, 10, IsolationLevel.ReadCommitted), "committed fetch")
    println("check committed-hw ${r.highWatermark}")
}
