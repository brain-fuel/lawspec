// User-owned LawSpec adapter: nap notes when it starts and ends a sleep.
package example;

public final class Overlap {
  static synchronized void note(String event, int n) {
    var path = System.getenv("LAWSPEC_SCHEDULE_LOG");
    if (path == null || path.isEmpty()) return;
    try {
      java.nio.file.Files.writeString(java.nio.file.Path.of(path),
          event + " " + n + " " + String.format(java.util.Locale.ROOT, "%.3f", System.nanoTime() / 1e6) + "\n",
          java.nio.file.StandardOpenOption.CREATE, java.nio.file.StandardOpenOption.APPEND);
    } catch (java.io.IOException e) {
      throw new java.io.UncheckedIOException(e);
    }
  }

  // (Int32 -> Bool)
  public static java.util.concurrent.CompletableFuture<java.lang.Boolean> nap(int value0) {
    return java.util.concurrent.CompletableFuture.supplyAsync(() -> {
      note("start", value0);
      try { Thread.sleep(300); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
      note("end", value0);
      return true;
    }, java.util.concurrent.Executors.newVirtualThreadPerTaskExecutor());
  }
}
