// The harness plane at run time (see docs/reference/language/harness.md):
// how a law's tests run, never what the law means. Generated tests call it
// for strategies (frequency, one of, such that), adequacy (cover, classify,
// label), run metadata (known failing, timeout, repeat, retry flaky) and
// benchmarks. Java and Kotlin tests share it.
//
// Statistics go to standard output, and, when LAWSPEC_STATS names a
// directory, to one JSON file per test there, which lawspec test reads.
package lawspec.testing;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.Predicate;
import java.util.function.Supplier;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Value;
import org.jetbrains.jetCheck.GenerationEnvironment;
import org.jetbrains.jetCheck.Generator;

public final class LawSpecHarness {
  private LawSpecHarness() {}

  /** A harness requirement failed: a strategy or an adequacy check. */
  public static final class HarnessError extends AssertionError {
    public HarnessError(String message) { super(message); }
  }

  /** A generated test, run by the harness. */
  @FunctionalInterface
  public interface Body { void run() throws Throwable; }

  public record Weighted(int weight, Supplier<Value> draw) {}

  // Statistics.

  private static String json(Object value) {
    if (value == null) return "null";
    if (value instanceof String s) {
      var out = new StringBuilder("\"");
      for (char c : s.toCharArray()) {
        if (c == '"' || c == '\\') out.append('\\').append(c);
        else if (c < 0x20) out.append(String.format("\\u%04x", (int) c));
        else out.append(c);
      }
      return out.append('"').toString();
    }
    if (value instanceof Map<?, ?> m) {
      var parts = new ArrayList<String>();
      for (var e : m.entrySet()) parts.add(json(String.valueOf(e.getKey())) + ":" + json(e.getValue()));
      return "{" + String.join(",", parts) + "}";
    }
    if (value instanceof List<?> l) {
      var parts = new ArrayList<String>();
      for (var item : l) parts.add(json(item));
      return "[" + String.join(",", parts) + "]";
    }
    return String.valueOf(value);
  }

  private static void record(String name, Map<String, Object> entry) {
    var directory = System.getenv("LAWSPEC_STATS");
    if (directory == null || directory.isEmpty()) return;
    try {
      Files.createDirectories(Path.of(directory));
      Files.writeString(Path.of(directory, name.replaceAll("[^A-Za-z0-9_-]", "_") + ".json"), json(entry), StandardCharsets.UTF_8);
    } catch (Exception ignored) {
      // Statistics are a convenience; a run never fails for want of them.
    }
  }

  // Strategies, drawn through JetCheck so failures shrink.

  /** A choice among n: a wide draw, reduced, so the weights hold. */
  public static int choose(GenerationEnvironment data, int n) {
    return data.generate(Generator.integers(0, Integer.MAX_VALUE)) % n;
  }

  public static Value frequency(GenerationEnvironment data, List<Weighted> alternatives) {
    int total = 0;
    for (var a : alternatives) total += a.weight();
    int pick = choose(data, total);
    for (var a : alternatives) {
      if (pick < a.weight()) return a.draw().get();
      pick -= a.weight();
    }
    return alternatives.get(alternatives.size() - 1).draw().get();
  }

  public static Value oneOf(GenerationEnvironment data, List<Supplier<Value>> values) {
    return values.get(choose(data, values.size())).get();
  }

  public static Value suchThat(Supplier<Value> draw, Predicate<Value> predicate, int limit, String strategy) {
    for (int i = 0; i <= limit; i++) {
      var value = draw.get();
      if (predicate.test(value)) return value;
    }
    throw new HarnessError("the strategy " + strategy + " discarded more than " + limit +
        " values; draw closer to what `such that` keeps, or allow more discards");
  }

  /** A drawn value must satisfy its input's refinements. */
  public static void checkDrawn(String strategy, String name, boolean holds, Value value) {
    if (!holds)
      throw new HarnessError("the strategy " + strategy + " produced " + value + " for " + name +
          ", which is outside the input's refinement; a strategy may only produce values of its type");
  }

  // Adequacy.

  private static final class Stats {
    int cases;
    final Map<String, Integer> cover = new TreeMap<>(), classes = new TreeMap<>(), labels = new TreeMap<>();
    Double best;
  }

  private static final Map<String, Stats> CASES = new LinkedHashMap<>();

  private static synchronized Stats stats(String law) { return CASES.computeIfAbsent(law, k -> new Stats()); }

  public static synchronized void observe(String law, String[] coverLabels, boolean[] covers,
      String[] classLabels, boolean[] classes, Value[] labels) {
    var s = stats(law);
    s.cases++;
    for (int i = 0; i < covers.length; i++) if (covers[i]) s.cover.merge(coverLabels[i], 1, Integer::sum);
    for (int i = 0; i < classes.length; i++) if (classes[i]) s.classes.merge(classLabels[i], 1, Integer::sum);
    for (var label : labels) s.labels.merge(String.valueOf(LawSpecRuntime.toNative("Text", label, 64)), 1, Integer::sum);
  }

  /** target maximize: JetCheck has no targeted search; the best score is reported. */
  public static synchronized void target(Value score, String law) {
    var s = stats(law);
    double value = Double.parseDouble(String.valueOf(score.data()));
    if (s.best == null || value > s.best) s.best = value;
  }

  private static synchronized Map<String, Object> adequacy(String law, int[] percents, String[] labels) {
    var s = CASES.remove(law);
    if (s == null) s = new Stats();
    var results = new ArrayList<Object>();
    var lines = new ArrayList<String>();
    lines.add(law + ": " + s.cases + " generated case(s)");
    for (int i = 0; i < percents.length; i++) {
      double observed = s.cases == 0 ? 0 : Math.round(10000.0 * s.cover.getOrDefault(labels[i], 0) / s.cases) / 100.0;
      boolean met = s.cases > 0 && observed >= percents[i];
      var r = new LinkedHashMap<String, Object>();
      r.put("label", labels[i]); r.put("required", percents[i]); r.put("observed", observed); r.put("met", met);
      results.add(r);
      lines.add("  cover " + percents[i] + "% \"" + labels[i] + "\": " + observed + "%" + (met ? "" : " (not met)"));
    }
    for (var e : s.classes.entrySet()) lines.add(String.format("  %s: %.1f%%", e.getKey(), 100.0 * e.getValue() / Math.max(1, s.cases)));
    for (var e : s.labels.entrySet()) lines.add(String.format("  label %s: %.1f%%", e.getKey(), 100.0 * e.getValue() / Math.max(1, s.cases)));
    if (s.best != null) lines.add("  best target score: " + s.best);
    System.out.println(String.join("\n", lines));
    var report = new LinkedHashMap<String, Object>();
    report.put("law", law); report.put("cases", s.cases); report.put("cover", results);
    report.put("classes", new LinkedHashMap<String, Object>(s.classes)); report.put("labels", new LinkedHashMap<String, Object>(s.labels));
    if (s.best != null) report.put("best", s.best);
    return report;
  }

  private static void once(Body test, long timeout, String law) throws Throwable {
    if (timeout <= 0) { test.run(); return; }
    var executor = Executors.newSingleThreadExecutor(r -> { var t = new Thread(r); t.setDaemon(true); return t; });
    try {
      var future = executor.submit(() -> { try { test.run(); } catch (Throwable t) { throw new ExecutionException(t); } return null; });
      future.get(timeout, TimeUnit.MILLISECONDS);
    } catch (TimeoutException e) {
      throw new HarnessError(law + " took longer than its timeout of " + timeout + " ms");
    } catch (ExecutionException e) {
      var cause = e.getCause() instanceof ExecutionException inner ? inner.getCause() : e.getCause();
      throw cause;
    } finally {
      executor.shutdownNow();
    }
  }

  /** Run one generated test of a law under its harness settings. */
  public static void run(String law, String name, long timeout, int repeat, int retries,
      int[] percents, String[] labels, boolean observed, Body test) throws Throwable {
    int attempts = 0;
    boolean flaky = false;
    Map<String, Object> report = null;
    while (true) {
      attempts++;
      try {
        for (int i = 0; i < repeat; i++) {
          synchronized (LawSpecHarness.class) { CASES.remove(law); }
          once(test, timeout, law);
          report = observed ? adequacy(law, percents, labels) : null;
          if (report != null) {
            var unmet = new ArrayList<String>();
            for (var r : (List<?>) report.get("cover")) {
              var m = (Map<?, ?>) r;
              if (!(Boolean) m.get("met"))
                unmet.add(law + ": cover " + m.get("required") + "% \"" + m.get("label") + "\" was not met (" +
                    m.get("observed") + "% of " + report.get("cases") + " generated cases)");
            }
            if (!unmet.isEmpty()) throw new HarnessError(String.join("; ", unmet));
          }
        }
        break;
      } catch (Throwable error) {
        if (error instanceof HarnessError || attempts > retries) {
          var entry = new LinkedHashMap<String, Object>();
          entry.put("law", law); entry.put("test", name); entry.put("outcome", "failed"); entry.put("attempts", attempts);
          record(name, entry);
          throw error;
        }
        flaky = true;
      }
    }
    var entry = new LinkedHashMap<String, Object>();
    entry.put("law", law); entry.put("test", name); entry.put("outcome", flaky ? "flaky" : "passed"); entry.put("attempts", attempts);
    if (report != null) entry.putAll(report);
    record(name, entry);
    if (flaky) System.out.println(law + " is flaky: it failed, then passed on attempt " + attempts);
  }

  /** A known-failing law's tests must fail; one that passes is reported. */
  public static void knownFailing(String law, String name, String reason, List<Body> tests) {
    var entry = new LinkedHashMap<String, Object>();
    entry.put("law", law); entry.put("test", name); entry.put("reason", reason);
    for (var test : tests) {
      try {
        test.run();
      } catch (Throwable error) {
        entry.put("outcome", "known-failing");
        record(name, entry);
        System.out.println(law + " is known to fail (" + reason + "): " + String.valueOf(error.getMessage()).lines().findFirst().orElse(""));
        return;
      }
    }
    entry.put("outcome", "known-failing-passed");
    record(name, entry);
    throw new HarnessError(law + " is marked known failing (" + reason + "), but it passes; remove `known failing` from its harness");
  }

  /** Measured, never asserted: the mean and fastest time of body. */
  public static void benchmark(String name, Body body) throws Throwable {
    var times = new ArrayList<Long>();
    long started = System.nanoTime();
    while (times.size() < 100000 && (System.nanoTime() - started < 200_000_000L || times.size() < 3)) {
      long before = System.nanoTime();
      body.run();
      times.add(System.nanoTime() - before);
    }
    long sum = 0, fastest = Long.MAX_VALUE;
    for (long t : times) { sum += t; fastest = Math.min(fastest, t); }
    long mean = sum / times.size();
    System.out.printf("benchmark %s: %d iteration(s), mean %.2f us, fastest %.2f us%n", name, times.size(), mean / 1000.0, fastest / 1000.0);
    var entry = new LinkedHashMap<String, Object>();
    entry.put("benchmark", name); entry.put("iterations", times.size()); entry.put("mean_ns", mean); entry.put("min_ns", fastest);
    record("benchmark " + name, entry);
  }
}
