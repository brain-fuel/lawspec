// User-owned LawSpec adapter: pause notes when it is called.
package example

object Sequencing {
    @Synchronized
    fun note(event: String, n: Int) {
        val path = System.getenv("LAWSPEC_SCHEDULE_LOG") ?: return
        if (path.isEmpty()) return
        java.io.File(path).appendText("$event $n ${String.format(java.util.Locale.ROOT, "%.3f", System.currentTimeMillis().toDouble())}\n")
    }

    // (Int32 -> Bool)
    fun pause(value0: kotlin.Int): kotlin.Boolean {
        note("start", value0)
        Thread.sleep(5)
        note("end", value0)
        return true
    }
}
