// The Kafka reference model's workload, driven through the generated
// cluster spec handler of the Broker ability: produce across 100
// partitions, a consumer group of ten members fetching and committing with a
// rebalance, then transactions. See bench/README.md.
package bench

import lawspec.abilities.lawtwin.Kafka
import lawspec.data.{FetchResult, IsolationLevel, KafkaError, OffsetEntry, ProducerTag, Record, TopicPartition}

object KafkaBench {
  val Partitions = 100
  val Members = 10
  val Fetch = 500

  def tp(p: Int): TopicPartition = TopicPartition("bench", p)

  def record(i: Long): Record = {
    val key = IArray.unsafeFromArray(java.nio.ByteBuffer.allocate(8).putLong(i).array())
    val value = IArray.fill[Byte](64)('x'.toByte)
    Record(Some(key), Some(value), Nil)
  }

  // Every request fails with KafkaError: a failure here is a bug in the workload.
  def ok[A](result: Either[KafkaError, A]): A = result.fold(error => throw IllegalStateException(error.toString), identity)

  def phase(name: String, ops: Long, start: Long): Unit =
    println(s"phase $name $ops ${"%.6f".format((System.nanoTime() - start) / 1e9)}")

  def memory(label: String): Unit = {
    for (_ <- 1 to 3) System.gc()
    val r = Runtime.getRuntime
    println(s"memory $label ${r.totalMemory() - r.freeMemory()}")
  }

  def main(args: Array[String]): Unit = {
    val scale = if (args.nonEmpty) args(0).toLong else 1000000L
    val worker = Thread(null, () => run(scale), "bench", 1L << 30)
    worker.start()
    worker.join()
  }

  def run(scale: Long): Unit = {
    val broker = Kafka.Cluster()
    val all = System.nanoTime()
    var total = 0L
    ok(broker.createTopicsRequest("bench", Partitions))

    var start = System.nanoTime()
    var i = 0L
    while (i < scale) {
      ok(broker.produceRequest(tp((i % Partitions).toInt), None, List(record(i))))
      i += 1
    }
    phase("produce", scale, start)
    total += scale
    memory("after-produce")

    start = System.nanoTime()
    var ops = 0L
    val members = (0 until Members).map(m => s"member-$m")
    var generation = 0
    for (m <- members) {
      generation = ok(broker.joinGroupRequest("g", m, List("bench")))
      ops += 1
    }
    var read = 0L
    for (round <- 0 until 2) {
      if (round == 1) {
        ok(broker.leaveGroupRequest("g", members.last))
        generation = ok(broker.joinGroupRequest("g", members.last, List("bench")))
        ops += 2
      }
      for (m <- members) {
        ok(broker.heartbeatRequest("g", m, generation))
        val assigned = ok(broker.syncGroupRequest("g", m, generation))
        ops += 2
        for (p <- assigned) {
          var position = broker.offsetFetchRequest("g", p).getOrElse(0L)
          ops += 1
          var reading = true
          while (reading) {
            val r: FetchResult = ok(broker.fetchRequest(p, position, Fetch, IsolationLevel.ReadUncommitted))
            ops += 1
            val end = if (round == 0) r.highWatermark / 2 else r.highWatermark
            if (r.records.isEmpty || position >= end) reading = false
            else {
              read += r.records.size
              position = r.nextOffset
              ok(broker.offsetCommitRequest("g", m, generation, List(OffsetEntry(p, position))))
              ops += 1
            }
          }
        }
      }
    }
    phase("consume", ops, start)
    total += ops
    println(s"check records-read $read")

    start = System.nanoTime()
    ops = 0
    val txns = math.max(1L, scale / 100)
    val id = ok(broker.initProducerIdRequest(Some("tx")))
    ops += 1
    val sequences = new Array[Int](Partitions)
    var t = 0L
    while (t < txns) {
      val parts = List(((2 * t) % Partitions).toInt, ((2 * t + 1) % Partitions).toInt)
      ok(broker.addPartitionsToTxnRequest("tx", id.producerId, id.producerEpoch, parts.map(tp)))
      for (p <- parts) {
        val tag = ProducerTag(id.producerId, id.producerEpoch, sequences(p))
        sequences(p) += 1
        ok(broker.produceRequest(tp(p), Some(tag), List(record(t))))
      }
      ok(broker.txnOffsetCommitRequest("tx", id.producerId, id.producerEpoch, "g", List(OffsetEntry(tp(parts.head), t))))
      ok(broker.endTxnRequest("tx", id.producerId, id.producerEpoch, true))
      ops += 5
      t += 1
    }
    phase("transactions", ops, start)
    total += ops
    phase("total", total, all)
    memory("end")
    val r = ok(broker.fetchRequest(tp(0), 0L, 10, IsolationLevel.ReadCommitted))
    println(s"check committed-hw ${r.highWatermark}")

    // The embedding API: a refusal as a value, and the state kept and put back.
    val refused = broker.produceRequest(TopicPartition("missing", 0), None, List(record(0)))
    println(s"check refused ${refused.left.toOption.map(_.productPrefix).getOrElse("nothing")}")
    val snapshot = broker.typedState
    ok(broker.produceRequest(tp(0), None, List(record(0))))
    broker.setTypedState(snapshot)
    val after = ok(broker.fetchRequest(tp(0), 0L, 10, IsolationLevel.ReadCommitted))
    println(s"check restored ${after.highWatermark == r.highWatermark}")
  }
}
