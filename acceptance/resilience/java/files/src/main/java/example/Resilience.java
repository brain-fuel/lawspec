// User-owned LawSpec adapter: the workflow runtime under test.
package example;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.function.Function;
import lawspec.runtime.LawSpecRuntime;

public final class Resilience {
  private static LawSpecRuntime.Retry retry(String strategy, long delay, long step, long factor) {
    return new LawSpecRuntime.Retry(strategy, delay, step, factor, -1, 0, "none", null, null);
  }

  public static Number runtimeExponentialDelay(BigInteger value0, BigInteger value1, BigInteger value2) {
    return BigInteger.valueOf(LawSpecRuntime.retryDelay(
        retry("exponential", value0.longValueExact(), 0, value1.longValueExact()), value2.longValueExact()));
  }

  public static Number runtimeLinearDelay(BigInteger value0, BigInteger value1, BigInteger value2) {
    return BigInteger.valueOf(LawSpecRuntime.retryDelay(
        retry("linear", value0.longValueExact(), value1.longValueExact(), 0), value2.longValueExact()));
  }

  public static Number runtimeFibonacciDelay(BigInteger value0, BigInteger value1) {
    return BigInteger.valueOf(LawSpecRuntime.retryDelay(
        retry("fibonacci", value0.longValueExact(), 0, 0), value1.longValueExact()));
  }

  public static List<BigInteger> splitMix(BigInteger value0, int value1) {
    var random = new LawSpecRuntime.SplitMix64(value0.longValue());
    var result = new ArrayList<BigInteger>();
    for (int i = 0; i < value1; i++) result.add(new BigInteger(Long.toUnsignedString(random.next())));
    return result;
  }

  public static Number fullJitter(BigInteger value0, BigInteger value1) {
    return BigInteger.valueOf(LawSpecRuntime.jittered(
        "full", value1.longValueExact(), 0, 0, new LawSpecRuntime.SplitMix64(value0.longValue())));
  }

  private static List<Number> waits(int attempts, Function<LawSpecRuntime.Value, Boolean> when) {
    var runtime = new LawSpecRuntime.WorkflowRuntime(new LawSpecRuntime.VirtualClock(), 0);
    var retry = new LawSpecRuntime.Retry("exponential", 100000, 0, 2, -1, attempts, "none", when, null);
    LawSpecRuntime.runStage(runtime.context(new HashMap<>()), new LawSpecRuntime.StagePolicy("stage", retry, -1),
        () -> new LawSpecRuntime.Value("Either", new LawSpecRuntime.Data("Either::Left", List.of(LawSpecRuntime.integer64(0)))));
    var result = new ArrayList<Number>();
    for (var event : runtime.trace) if (event.kind().equals("sleep")) result.add(BigInteger.valueOf(event.number()));
    return result;
  }

  public static List<Number> retriedWaits(int value0) {
    return waits(value0, null);
  }

  public static List<Number> rejectedWaits(int value0) {
    return waits(value0, error -> false);
  }

  /** Calls the generated workflow at each time under one runtime. */
  public static List<Boolean> limitedAt(List<Number> value0) {
    var clock = new LawSpecRuntime.VirtualClock();
    var runtime = new LawSpecRuntime.WorkflowRuntime(clock, 0);
    var admitted = new ArrayList<Boolean>();
    for (var time : value0) {
      clock.time = new BigInteger(time.toString()).longValueExact();
      admitted.add(lawspec.definitions.example.Limits.limited(runtime.context(new HashMap<>()), new lawspec.data.Ticket(0L))
          instanceof LawSpecRuntime.Right);
    }
    return admitted;
  }

  /** Books a ticket under a fresh runtime: the stages whose undos ran. */
  public static List<String> compensationsFor(long value0) {
    var runtime = new LawSpecRuntime.WorkflowRuntime(new LawSpecRuntime.VirtualClock(), 0);
    lawspec.definitions.example.Limits.book(runtime.context(new HashMap<>()), new lawspec.data.Ticket(value0));
    var stages = new ArrayList<String>();
    for (var event : runtime.trace) if (event.kind().equals("compensate")) stages.add(event.stage());
    return stages;
  }

  /** Quotes a ticket under a runtime with the real clock: whether it succeeded within 400ms, for ticket -2 through a hedged attempt. */
  public static java.util.concurrent.CompletableFuture<Boolean> quoteHedged(long value0) {
    return java.util.concurrent.CompletableFuture.supplyAsync(() -> {
      Limits.resetQuotes();
      var runtime = new LawSpecRuntime.WorkflowRuntime(null, 0);
      long started = System.nanoTime();
      var result = lawspec.definitions.example.Limits.hedged(runtime.context(new HashMap<>()), new lawspec.data.Ticket(value0));
      boolean quick = System.nanoTime() - started < 400_000_000L;
      boolean hedged = runtime.trace.stream().anyMatch(event -> event.kind().equals("hedge"));
      return result instanceof LawSpecRuntime.Right<?, ?> && quick && (value0 != -2 || hedged);
    });
  }

  /** Quotes a ticket under a runtime with the real clock: whether it timed out. */
  public static java.util.concurrent.CompletableFuture<Boolean> quoteTimedOut(long value0) {
    return java.util.concurrent.CompletableFuture.supplyAsync(() -> {
      var runtime = new LawSpecRuntime.WorkflowRuntime(null, 0);
      var result = lawspec.definitions.example.Limits.quoted(runtime.context(new HashMap<>()), new lawspec.data.Ticket(value0));
      return result instanceof LawSpecRuntime.Left<?, ?> left && left.value() instanceof lawspec.data.QuotedError.QuotedTimedOut;
    });
  }
}
