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
}
