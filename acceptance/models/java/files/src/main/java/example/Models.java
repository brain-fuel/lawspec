// User-owned LawSpec adapter: a stack and an atomic counter.
package example;

import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import lawspec.data.Counter;
import lawspec.data.PeekFlow;
import lawspec.data.PopFlow;
import lawspec.data.PushFlow;
import lawspec.data.Stack;
import lawspec.runtime.LawSpecRuntime;

public final class Models {
  private static final ConcurrentHashMap<Integer, AtomicLong> counters = new ConcurrentHashMap<>();
  private static final AtomicInteger ids = new AtomicInteger();

  public static Stack empty(LawSpecRuntime.Value value0) {
    return new Stack.Empty();
  }

  public static PushFlow push(byte value0, Stack value1) {
    return new PushFlow(new Stack.Push(value0, value1));
  }

  // The flow signature guarantees a nonempty stack.
  public static PopFlow pop(Stack value0) {
    var cell = (Stack.Push) value0;
    return new PopFlow(cell.top(), cell.rest());
  }

  public static PeekFlow peek(Stack value0) {
    var cell = (Stack.Push) value0;
    return new PeekFlow(cell.top(), cell);
  }

  public static Counter newCounter(LawSpecRuntime.Value value0) {
    int id = ids.incrementAndGet();
    counters.put(id, new AtomicLong());
    return new Counter(id);
  }

  public static CompletableFuture<Long> increment(Counter value0) {
    return CompletableFuture.supplyAsync(() -> counters.get(value0.id()).incrementAndGet());
  }

  public static CompletableFuture<Long> decrement(Counter value0) {
    return CompletableFuture.supplyAsync(() -> counters.get(value0.id()).decrementAndGet());
  }

  public static CompletableFuture<Long> read(Counter value0) {
    return CompletableFuture.supplyAsync(() -> counters.get(value0.id()).get());
  }
}
