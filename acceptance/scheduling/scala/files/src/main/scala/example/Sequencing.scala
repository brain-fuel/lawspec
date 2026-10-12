// User-owned LawSpec adapter: pause notes when it is called.
package example

object Sequencing {
  def note(event: String, n: Int): Unit = synchronized {
    val path = System.getenv("LAWSPEC_SCHEDULE_LOG")
    if (path != null && path.nonEmpty)
      java.nio.file.Files.writeString(java.nio.file.Path.of(path),
        s"$event $n ${String.format(java.util.Locale.ROOT, "%.3f", System.currentTimeMillis().toDouble)}\n",
        java.nio.file.StandardOpenOption.CREATE, java.nio.file.StandardOpenOption.APPEND)
  }

  // (Int32 -> Bool)
  def pause(value0: scala.Int): scala.Boolean = {
    note("start", value0)
    Thread.sleep(5)
    note("end", value0)
    true
  }
}
