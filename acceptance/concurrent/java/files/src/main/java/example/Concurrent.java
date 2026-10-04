// User-owned LawSpec adapter: a queue, a set and a map shared between
// threads, each one of the JVM's own concurrent structures.
package example;

import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicInteger;
import lawspec.data.Cache;
import lawspec.data.Tags;
import lawspec.data.WorkQueue;
import lawspec.runtime.LawSpecRuntime;

public final class Concurrent {
  private static final AtomicInteger ids = new AtomicInteger();
  private static final ConcurrentHashMap<Integer, ConcurrentLinkedQueue<Integer>> queues =
      new ConcurrentHashMap<>();
  private static final ConcurrentHashMap<Integer, Set<Integer>> sets = new ConcurrentHashMap<>();
  private static final ConcurrentHashMap<Integer, ConcurrentHashMap<Byte, Long>> maps =
      new ConcurrentHashMap<>();

  // A structure by its handle; generated tests may name one first.
  private static ConcurrentLinkedQueue<Integer> queue(WorkQueue handle) {
    return queues.computeIfAbsent(handle.id(), k -> new ConcurrentLinkedQueue<>());
  }

  private static Set<Integer> set(Tags handle) {
    return sets.computeIfAbsent(handle.id(), k -> ConcurrentHashMap.newKeySet());
  }

  private static ConcurrentHashMap<Byte, Long> map(Cache handle) {
    return maps.computeIfAbsent(handle.id(), k -> new ConcurrentHashMap<>());
  }

  private static <T> LawSpecRuntime.Maybe<T> maybe(T value) {
    return value == null ? new LawSpecRuntime.Nothing<>() : new LawSpecRuntime.Just<>(value);
  }

  public static WorkQueue newQueue(LawSpecRuntime.Value value0) {
    var handle = new WorkQueue(ids.incrementAndGet());
    queue(handle);
    return handle;
  }

  public static CompletableFuture<LawSpecRuntime.Value> offer(WorkQueue value0, int value1) {
    return CompletableFuture.supplyAsync(
        () -> {
          queue(value0).offer(value1);
          return LawSpecRuntime.absent("Unit");
        });
  }

  public static CompletableFuture<LawSpecRuntime.Maybe<Integer>> poll(WorkQueue value0) {
    return CompletableFuture.supplyAsync(
        () -> {
          var q = queue(value0);
          return maybe(q.poll());
        });
  }

  public static CompletableFuture<Long> queueSize(WorkQueue value0) {
    return CompletableFuture.supplyAsync(() -> (long) queue(value0).size());
  }

  public static Tags newTags(LawSpecRuntime.Value value0) {
    var handle = new Tags(ids.incrementAndGet());
    set(handle);
    return handle;
  }

  public static CompletableFuture<Boolean> tag(Tags value0, int value1) {
    return CompletableFuture.supplyAsync(() -> set(value0).add(value1));
  }

  public static CompletableFuture<Boolean> untag(Tags value0, int value1) {
    return CompletableFuture.supplyAsync(() -> set(value0).remove(value1));
  }

  public static CompletableFuture<Boolean> tagged(Tags value0, int value1) {
    return CompletableFuture.supplyAsync(() -> set(value0).contains(value1));
  }

  public static Cache newCache(LawSpecRuntime.Value value0) {
    var handle = new Cache(ids.incrementAndGet());
    map(handle);
    return handle;
  }

  public static CompletableFuture<LawSpecRuntime.Maybe<Long>> store(
      Cache value0, byte value1, long value2) {
    return CompletableFuture.supplyAsync(() -> maybe(map(value0).put(value1, value2)));
  }

  public static CompletableFuture<LawSpecRuntime.Maybe<Long>> fetch(Cache value0, byte value1) {
    return CompletableFuture.supplyAsync(() -> maybe(map(value0).get(value1)));
  }

  public static CompletableFuture<LawSpecRuntime.Maybe<Long>> evict(Cache value0, byte value1) {
    return CompletableFuture.supplyAsync(() -> maybe(map(value0).remove(value1)));
  }
}
