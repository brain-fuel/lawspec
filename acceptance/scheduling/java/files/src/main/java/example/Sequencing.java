// User-owned LawSpec adapter: pause notes when it is called.
package example;

public final class Sequencing {
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
  public static boolean pause(int value0) {
    note("start", value0);
    try { Thread.sleep(5); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    note("end", value0);
    return true;
  }
}
