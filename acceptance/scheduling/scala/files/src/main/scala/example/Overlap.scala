// User-owned LawSpec adapter: nap notes when it starts and ends a sleep.
package example

object Overlap {
  def note(event: String, n: Int): Unit = synchronized {
    val path = System.getenv("LAWSPEC_SCHEDULE_LOG")
    if (path != null && path.nonEmpty)
      java.nio.file.Files.writeString(java.nio.file.Path.of(path),
        s"$event $n ${String.format(java.util.Locale.ROOT, "%.3f", System.currentTimeMillis().toDouble)}\n",
        java.nio.file.StandardOpenOption.CREATE, java.nio.file.StandardOpenOption.APPEND)
  }

  // (Int32 -> Bool)
  def nap(value0: scala.Int): scala.concurrent.Future[scala.Boolean] =
    scala.concurrent.Future {
      note("start", value0)
      Thread.sleep(300)
      note("end", value0)
      true
    }(scala.concurrent.ExecutionContext.global)
}
