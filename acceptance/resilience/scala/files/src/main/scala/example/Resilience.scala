// User-owned LawSpec adapter: the workflow runtime under test.
package example

import lawspec.runtime.LawSpecRuntime
import scala.concurrent.{ExecutionContext, Future, blocking}
import scala.jdk.CollectionConverters.*

object Resilience {
  private given ExecutionContext = ExecutionContext.global

  type Integer = scala.Int | scala.Long | scala.math.BigInt

  private def retry(strategy: String, delay: Long, step: Long, factor: Long) =
    LawSpecRuntime.Retry(strategy, delay, step, factor, -1, 0, "none", null, null)

  def runtimeExponentialDelay(value0: BigInt, value1: BigInt, value2: BigInt): Integer =
    BigInt(LawSpecRuntime.retryDelay(retry("exponential", value0.toLong, 0, value1.toLong), value2.toLong))

  def runtimeLinearDelay(value0: BigInt, value1: BigInt, value2: BigInt): Integer =
    BigInt(LawSpecRuntime.retryDelay(retry("linear", value0.toLong, value1.toLong, 0), value2.toLong))

  def runtimeFibonacciDelay(value0: BigInt, value1: BigInt): Integer =
    BigInt(LawSpecRuntime.retryDelay(retry("fibonacci", value0.toLong, 0, 0), value1.toLong))

  def splitMix(value0: BigInt, value1: Int): List[BigInt] = {
    val random = LawSpecRuntime.SplitMix64(value0.toLong)
    List.fill(value1)(BigInt(java.lang.Long.toUnsignedString(random.next())))
  }

  def fullJitter(value0: BigInt, value1: BigInt): Integer =
    BigInt(LawSpecRuntime.jittered("full", value1.toLong, 0, 0, LawSpecRuntime.SplitMix64(value0.toLong)))

  private def waits(attempts: Int, rejects: Boolean): List[BigInt] = {
    val runtime = LawSpecRuntime.WorkflowRuntime(LawSpecRuntime.VirtualClock(), 0)
    val reject: java.util.function.Function[LawSpecRuntime.Value, java.lang.Boolean] =
      if (rejects) (_ => java.lang.Boolean.FALSE) else null
    val retry = LawSpecRuntime.Retry(
      "exponential", 100000, 0, 2, -1, attempts.toLong, "none",
      reject, null,
    )
    LawSpecRuntime.runStage(runtime.context(java.util.HashMap()), LawSpecRuntime.StagePolicy("stage", retry, -1), () =>
      LawSpecRuntime.Value("Either", LawSpecRuntime.Data("Either::Left", java.util.List.of(LawSpecRuntime.integer64(0))))
    )
    runtime.trace.asScala.toList.filter(_.kind() == "sleep").map(event => BigInt(event.number()))
  }

  def retriedWaits(value0: Int): List[BigInt] = waits(value0, false)

  def rejectedWaits(value0: Int): List[BigInt] = waits(value0, true)

  /** Calls the generated workflow at each time under one runtime. */
  def limitedAt(value0: List[BigInt]): List[Boolean] = {
    val clock = LawSpecRuntime.VirtualClock()
    val runtime = LawSpecRuntime.WorkflowRuntime(clock, 0)
    value0.map { time =>
      clock.time = time.toLong
      lawspec.definitions.example.Limits.limited(runtime.context(java.util.HashMap()), lawspec.data.Ticket(0L)).isRight
    }
  }

  /** Books a ticket under a fresh runtime: the stages whose undos ran. */
  def compensationsFor(value0: Long): List[String] = {
    val runtime = LawSpecRuntime.WorkflowRuntime(LawSpecRuntime.VirtualClock(), 0)
    lawspec.definitions.example.Limits.book(runtime.context(java.util.HashMap()), lawspec.data.Ticket(value0))
    runtime.trace.asScala.toList.filter(_.kind() == "compensate").map(_.stage())
  }

  // Quotes a ticket under a runtime with the real clock: whether it succeeded
  // within 400ms, for ticket -2 through a hedged attempt.
  def quoteHedged(value0: Long): Future[Boolean] = Future {
    blocking {
      Limits.resetQuotes()
      val runtime = LawSpecRuntime.WorkflowRuntime(null, 0)
      val started = System.nanoTime()
      val result = lawspec.definitions.example.Limits.hedged(runtime.context(java.util.HashMap()), lawspec.data.Ticket(value0))
      val quick = System.nanoTime() - started < 400000000L
      val hedged = runtime.trace.asScala.exists(_.kind() == "hedge")
      result.isRight && quick && (value0 != -2L || hedged)
    }
  }

  // Quotes a ticket under a runtime with the real clock: whether it timed out.
  def quoteTimedOut(value0: Long): Future[Boolean] = Future {
    blocking {
      val runtime = LawSpecRuntime.WorkflowRuntime(null, 0)
      lawspec.definitions.example.Limits.quoted(runtime.context(java.util.HashMap()), lawspec.data.Ticket(value0)) match {
        case Left(lawspec.data.QuotedError.QuotedTimedOut) => true
        case _ => false
      }
    }
  }
}
