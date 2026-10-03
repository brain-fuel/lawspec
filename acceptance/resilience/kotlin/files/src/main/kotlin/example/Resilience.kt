// User-owned LawSpec adapter: the workflow runtime under test.
package example

import java.math.BigInteger
import lawspec.runtime.LawSpecRuntime

object Resilience {
    private fun retry(strategy: String, delay: Long, step: Long, factor: Long) =
        LawSpecRuntime.Retry(strategy, delay, step, factor, -1, 0, "none", null, null)

    fun runtimeExponentialDelay(value0: BigInteger, value1: BigInteger, value2: BigInteger): Number =
        BigInteger.valueOf(LawSpecRuntime.retryDelay(retry("exponential", value0.toLong(), 0, value1.toLong()), value2.toLong()))

    fun runtimeLinearDelay(value0: BigInteger, value1: BigInteger, value2: BigInteger): Number =
        BigInteger.valueOf(LawSpecRuntime.retryDelay(retry("linear", value0.toLong(), value1.toLong(), 0), value2.toLong()))

    fun runtimeFibonacciDelay(value0: BigInteger, value1: BigInteger): Number =
        BigInteger.valueOf(LawSpecRuntime.retryDelay(retry("fibonacci", value0.toLong(), 0, 0), value1.toLong()))

    fun splitMix(value0: BigInteger, value1: Int): List<BigInteger> {
        val random = LawSpecRuntime.SplitMix64(value0.toLong())
        return List(value1) { BigInteger(java.lang.Long.toUnsignedString(random.next())) }
    }

    fun fullJitter(value0: BigInteger, value1: BigInteger): Number =
        BigInteger.valueOf(LawSpecRuntime.jittered("full", value1.toLong(), 0, 0, LawSpecRuntime.SplitMix64(value0.toLong())))

    private fun waits(attempts: Int, rejects: Boolean): List<BigInteger> {
        val runtime = LawSpecRuntime.WorkflowRuntime(LawSpecRuntime.VirtualClock(), 0)
        val retry = LawSpecRuntime.Retry(
            "exponential", 100000, 0, 2, -1, attempts.toLong(), "none",
            if (rejects) java.util.function.Function { _: LawSpecRuntime.Value -> false } else null, null,
        )
        LawSpecRuntime.runStage(runtime.context(HashMap()), LawSpecRuntime.StagePolicy("stage", retry, -1)) {
            LawSpecRuntime.Value("Either", LawSpecRuntime.Data("Either::Left", listOf(LawSpecRuntime.integer64(0))))
        }
        return runtime.trace.filter { it.kind() == "sleep" }.map { BigInteger.valueOf(it.number()) }
    }

    fun retriedWaits(value0: Int): List<BigInteger> = waits(value0, false)

    fun rejectedWaits(value0: Int): List<BigInteger> = waits(value0, true)

    /** Calls the generated workflow at each time under one runtime. */
    fun limitedAt(value0: List<BigInteger>): List<Boolean> {
        val clock = LawSpecRuntime.VirtualClock()
        val runtime = LawSpecRuntime.WorkflowRuntime(clock, 0)
        return value0.map { time ->
            clock.time = time.toLong()
            lawspec.definitions.example.Limits.limited(runtime.context(HashMap()), lawspec.data.Ticket(0)) is LawSpecRuntime.Right
        }
    }

    /** Books a ticket under a fresh runtime: the stages whose undos ran. */
    fun compensationsFor(value0: Long): List<String> {
        val runtime = LawSpecRuntime.WorkflowRuntime(LawSpecRuntime.VirtualClock(), 0)
        lawspec.definitions.example.Limits.book(runtime.context(HashMap()), lawspec.data.Ticket(value0))
        return runtime.trace.filter { it.kind() == "compensate" }.map { it.stage() }
    }

    // Quotes a ticket under a runtime with the real clock: whether it succeeded
    // within 400ms, for ticket -2 through a hedged attempt.
    suspend fun quoteHedged(value0: Long): Boolean {
        Limits.resetQuotes()
        val runtime = LawSpecRuntime.WorkflowRuntime(null, 0)
        val started = System.nanoTime()
        val result = lawspec.definitions.example.Limits.hedged(runtime.context(HashMap()), lawspec.data.Ticket(value0))
        val quick = System.nanoTime() - started < 400_000_000L
        val hedged = runtime.trace.any { it.kind() == "hedge" }
        return result is LawSpecRuntime.Right<*, *> && quick && (value0 != -2L || hedged)
    }

    // Quotes a ticket under a runtime with the real clock: whether it timed out.
    suspend fun quoteTimedOut(value0: Long): Boolean {
        val runtime = LawSpecRuntime.WorkflowRuntime(null, 0)
        val result = lawspec.definitions.example.Limits.quoted(runtime.context(HashMap()), lawspec.data.Ticket(value0))
        return result is LawSpecRuntime.Left<*, *> && result.value is lawspec.data.QuotedError.QuotedTimedOut
    }
}
