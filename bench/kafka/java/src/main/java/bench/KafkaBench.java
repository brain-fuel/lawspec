package bench;

import java.util.ArrayList;
import java.util.List;
import lawspec.abilities.lawtwin.kafka.Contract;
import lawspec.data.FetchResult;
import lawspec.data.IsolationLevel;
import lawspec.data.OffsetEntry;
import lawspec.data.ProducerIdAndEpoch;
import lawspec.data.ProducerTag;
import lawspec.data.Record;
import lawspec.data.TopicPartition;
import lawspec.runtime.LawSpecRuntime;

/**
 * The Kafka reference model's workload, driven through the generated reference spec handler of the
 * Broker ability: produce across 100 partitions, a consumer group of ten members fetching and
 * committing with a rebalance, then transactions. See bench/README.md.
 */
public final class KafkaBench {
  static final int PARTITIONS = 100;
  static final int MEMBERS = 10;
  static final int FETCH = 500;

  static TopicPartition tp(int p) {
    return new TopicPartition("bench", p);
  }

  static Record record(long i) {
    byte[] key = java.nio.ByteBuffer.allocate(8).putLong(i).array();
    byte[] value = new byte[64];
    java.util.Arrays.fill(value, (byte) 'x');
    return new Record(new LawSpecRuntime.Just<>(key), new LawSpecRuntime.Just<>(value), List.of());
  }

  static <A, B> B right(LawSpecRuntime.Either<A, B> e, String what) {
    if (e instanceof LawSpecRuntime.Right<A, B> r) return r.value();
    throw new IllegalStateException(what + ": " + ((LawSpecRuntime.Left<A, B>) e).value());
  }

  static void phase(String name, long ops, long start) {
    System.out.printf("phase %s %d %.6f%n", name, ops, (System.nanoTime() - start) / 1e9);
  }

  static void memory(String label) {
    for (int i = 0; i < 3; i++) System.gc();
    Runtime r = Runtime.getRuntime();
    System.out.println("memory " + label + " " + (r.totalMemory() - r.freeMemory()));
  }

  public static void main(String[] args) throws Exception {
    long scale = args.length > 0 ? Long.parseLong(args[0]) : 1_000_000L;
    Thread worker = new Thread(null, () -> run(scale), "bench", 1L << 30);
    worker.start();
    worker.join();
  }

  static void run(long scale) {
    var broker = new Contract.Reference();
    long all = System.nanoTime();
    long total = 0;
    right(broker.createTopicsRequest("bench", PARTITIONS), "create topic");

    long start = System.nanoTime();
    for (long i = 0; i < scale; i++) {
      right(broker.produceRequest(tp((int) (i % PARTITIONS)), new LawSpecRuntime.Nothing<>(), List.of(record(i))), "produce");
    }
    phase("produce", scale, start);
    total += scale;
    memory("after-produce");

    start = System.nanoTime();
    long ops = 0;
    var members = new ArrayList<String>();
    for (int m = 0; m < MEMBERS; m++) members.add("member-" + m);
    int generation = 0;
    for (String m : members) {
      generation = right(broker.joinGroupRequest("g", m, List.of("bench")), "join");
      ops++;
    }
    long read = 0;
    for (int round = 0; round < 2; round++) {
      if (round == 1) {
        right(broker.leaveGroupRequest("g", members.get(MEMBERS - 1)), "leave");
        generation = right(broker.joinGroupRequest("g", members.get(MEMBERS - 1), List.of("bench")), "rejoin");
        ops += 2;
      }
      for (String m : members) {
        right(broker.heartbeatRequest("g", m, generation), "heartbeat");
        List<TopicPartition> assigned = right(broker.syncGroupRequest("g", m, generation), "sync");
        ops += 2;
        for (TopicPartition p : assigned) {
          var committed = broker.offsetFetchRequest("g", p);
          long position = committed instanceof LawSpecRuntime.Just<Long> j ? j.value() : 0L;
          ops++;
          while (true) {
            FetchResult r = right(broker.fetchRequest(p, position, FETCH, new IsolationLevel.ReadUncommitted()), "fetch");
            ops++;
            long end = round == 0 ? r.highWatermark() / 2 : r.highWatermark();
            if (r.records().isEmpty() || position >= end) break;
            read += r.records().size();
            position = r.nextOffset();
            right(broker.offsetCommitRequest("g", m, generation, List.of(new OffsetEntry(p, position))), "commit");
            ops++;
          }
        }
      }
    }
    phase("consume", ops, start);
    total += ops;
    System.out.println("check records-read " + read);

    start = System.nanoTime();
    ops = 0;
    long txns = Math.max(1, scale / 100);
    ProducerIdAndEpoch id = right(broker.initProducerIdRequest(new LawSpecRuntime.Just<>("tx")), "init producer");
    ops++;
    int[] sequences = new int[PARTITIONS];
    for (long t = 0; t < txns; t++) {
      int[] parts = {(int) ((2 * t) % PARTITIONS), (int) ((2 * t + 1) % PARTITIONS)};
      right(broker.addPartitionsToTxnRequest("tx", id.producerId(), id.producerEpoch(), List.of(tp(parts[0]), tp(parts[1]))), "add partitions");
      for (int p : parts) {
        var tag = new ProducerTag(id.producerId(), id.producerEpoch(), sequences[p]++);
        right(broker.produceRequest(tp(p), new LawSpecRuntime.Just<>(tag), List.of(record(t))), "transactional produce");
      }
      right(broker.txnOffsetCommitRequest("tx", id.producerId(), id.producerEpoch(), "g", List.of(new OffsetEntry(tp(parts[0]), t))), "txn offsets");
      right(broker.endTxnRequest("tx", id.producerId(), id.producerEpoch(), true), "commit");
      ops += 5;
    }
    phase("transactions", ops, start);
    total += ops;
    phase("total", total, all);
    memory("end");
    FetchResult r = right(broker.fetchRequest(tp(0), 0L, 10, new IsolationLevel.ReadCommitted()), "committed fetch");
    System.out.println("check committed-hw " + r.highWatermark());
  }
}
