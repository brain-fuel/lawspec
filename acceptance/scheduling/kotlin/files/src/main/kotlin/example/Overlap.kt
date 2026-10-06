// User-owned LawSpec adapter: nap notes when it starts and ends a sleep.
package example

object Overlap {
    @Synchronized
    fun note(event: String, n: Int) {
        val path = System.getenv("LAWSPEC_SCHEDULE_LOG") ?: return
        if (path.isEmpty()) return
        java.io.File(path).appendText("$event $n ${String.format(java.util.Locale.ROOT, "%.3f", System.currentTimeMillis().toDouble())}\n")
    }

    // (Int32 -> Bool)
    suspend fun nap(value0: kotlin.Int): kotlin.Boolean {
        note("start", value0)
        kotlinx.coroutines.delay(300)
        note("end", value0)
        return true
    }
}
