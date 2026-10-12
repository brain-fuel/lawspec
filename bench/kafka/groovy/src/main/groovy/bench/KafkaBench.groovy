package bench

import java.util.ArrayList
import java.util.List
import lawspec.abilities.lawtwin.Kafka
import lawspec.data.FetchResult
import lawspec.data.IsolationLevel
import lawspec.data.OffsetEntry
import lawspec.data.ProducerIdAndEpoch
import lawspec.data.ProducerTag
import lawspec.data.Record
import lawspec.data.TopicPartition
import lawspec.runtime.LawSpecRuntime

/**
 * The Kafka reference model's workload, driven through the generated cluster spec handler of the
 * Broker ability: produce across 100 partitions, a consumer group of ten members fetching and
 * committing with a rebalance, then transactions. See bench/README.md.
 */
@groovy.transform.CompileStatic
final class KafkaBench {
  static final int PARTITIONS = 100
  static final int MEMBERS = 10
  static final int FETCH = 500

  static TopicPartition tp(int p) {
    return new TopicPartition('bench', p)
  }

  static Record record(long i) {
    byte[] key = java.nio.ByteBuffer.allocate(8).putLong(i).array()
    byte[] value = new byte[64]
    java.util.Arrays.fill(value, (byte) ((char) 'x'))
    return new Record(new LawSpecRuntime.Just<>(key), new LawSpecRuntime.Just<>(value), List.of())
  }

  static void phase(String name, long ops, long start) {
    System.out.printf('phase %s %d %.6f%n', name, ops, (System.nanoTime() - start) / 1e9d)
  }

  static void memory(String label) {
    for (int i = 0; i < 3; i++) System.gc();
    Runtime r = Runtime.getRuntime()
    System.out.println('memory ' + label + ' ' + (r.totalMemory() - r.freeMemory()))
  }

  static void main(String[] args) throws Exception {
    long scale = args.length > 0 ? Long.parseLong(args[0]) : 1_000_000L
    Thread worker = new Thread(null, () -> workload(scale), 'bench', 1L << 30)
    worker.start()
    worker.join()
  }

  static void workload(long scale) {
    var broker = new Kafka.Cluster()
    long all = System.nanoTime()
    long total = 0
    broker.createTopicsRequest('bench', PARTITIONS)

    long start = System.nanoTime()
    for (long i = 0; i < scale; i++) {
      broker.produceRequest(tp((int) (i % PARTITIONS)), new LawSpecRuntime.Nothing<>(), List.of(record(i)))
    }
    phase('produce', scale, start)
    total += scale
    memory('after-produce')

    start = System.nanoTime()
    long ops = 0
    var members = new ArrayList<String>()
    for (int m = 0; m < MEMBERS; m++) members.add('member-' + m);
    int generation = 0
    for (String m : members) {
      generation = broker.joinGroupRequest('g', m, List.of('bench'))
      ops++
    }
    long read = 0
    for (int round = 0; round < 2; round++) {
      if (round == 1) {
        broker.leaveGroupRequest('g', members.get(MEMBERS - 1))
        generation = broker.joinGroupRequest('g', members.get(MEMBERS - 1), List.of('bench'))
        ops += 2
      }
      for (String m : members) {
        broker.heartbeatRequest('g', m, generation)
        List<TopicPartition> assigned = broker.syncGroupRequest('g', m, generation)
        ops += 2
        for (TopicPartition p : assigned) {
          var committed = broker.offsetFetchRequest('g', p)
          long position = committed instanceof LawSpecRuntime.Just j ? (Long) j.value() : 0L
          ops++
          while (true) {
            FetchResult r = broker.fetchRequest(p, position, FETCH, new IsolationLevel.ReadUncommitted())
            ops++
            long end = round == 0 ? r.highWatermark().intdiv(2) : r.highWatermark()
            if (r.records().isEmpty() || position >= end) break
            read += r.records().size()
            position = r.nextOffset()
            broker.offsetCommitRequest('g', m, generation, List.of(new OffsetEntry(p, position)))
            ops++
          }
        }
      }
    }
    phase('consume', ops, start)
    total += ops
    System.out.println('check records-read ' + read)

    start = System.nanoTime()
    ops = 0
    long txns = Math.max(1L, scale.intdiv(100))
    ProducerIdAndEpoch id = broker.initProducerIdRequest(new LawSpecRuntime.Just<>('tx'))
    ops++
    int[] sequences = new int[PARTITIONS]
    for (long t = 0; t < txns; t++) {
      int[] parts = [(int) ((2 * t) % PARTITIONS), (int) ((2 * t + 1) % PARTITIONS)] as int[]
      broker.addPartitionsToTxnRequest('tx', id.producerId(), id.producerEpoch(), List.of(tp(parts[0]), tp(parts[1])))
      for (int p : parts) {
        var tag = new ProducerTag(id.producerId(), id.producerEpoch(), sequences[p]++)
        broker.produceRequest(tp(p), new LawSpecRuntime.Just<>(tag), List.of(record(t)))
      }
      broker.txnOffsetCommitRequest('tx', id.producerId(), id.producerEpoch(), 'g', List.of(new OffsetEntry(tp(parts[0]), t)))
      broker.endTxnRequest('tx', id.producerId(), id.producerEpoch(), true)
      ops += 5
    }
    phase('transactions', ops, start)
    total += ops
    phase('total', total, all)
    memory('end')
    FetchResult r = broker.fetchRequest(tp(0), 0L, 10, new IsolationLevel.ReadCommitted())
    System.out.println('check committed-hw ' + r.highWatermark())

    // The embedding API: a refusal as a value, and the state kept and put back.
    var refused = broker.tryProduceRequest(new TopicPartition('missing', 0), new LawSpecRuntime.Nothing<>(), List.of(record(0)))
    System.out.println('check refused ' + (refused.failed() ? refused.failure().getClass().getSimpleName() : 'nothing'))
    var snapshot = broker.typedState()
    broker.produceRequest(tp(0), new LawSpecRuntime.Nothing<>(), List.of(record(0)))
    broker.setTypedState(snapshot)
    FetchResult after = broker.fetchRequest(tp(0), 0L, 10, new IsolationLevel.ReadCommitted())
    System.out.println('check restored ' + after.highWatermark().equals(r.highWatermark()))
    java.util.function.Supplier<?> nativeState = broker::state
  }
}
