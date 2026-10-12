// User-owned LawSpec adapter.
package example

import lawspec.runtime.LawSpecRuntime

@groovy.transform.CompileStatic
final class Limits {
  static lawspec.runtime.LawSpecRuntime.Either<String, lawspec.data.Ticket> admitTicket(lawspec.data.Ticket value0) {
    return new LawSpecRuntime.Right<>(value0)
  }

  static lawspec.runtime.LawSpecRuntime.Either<String, lawspec.data.Ticket> reserveSeat(lawspec.data.Ticket value0) {
    return new LawSpecRuntime.Right<>(value0)
  }

  static lawspec.runtime.LawSpecRuntime.Either<String, lawspec.data.Ticket> chargeCard(lawspec.data.Ticket value0) {
    if (value0.number() < 0) return new LawSpecRuntime.Left<>('declined')
    return new LawSpecRuntime.Right<>(value0)
  }

  static boolean releaseSeat(lawspec.data.Ticket value0) {
    return true
  }

  private static final java.util.concurrent.atomic.AtomicLong quotes = new java.util.concurrent.atomic.AtomicLong()

  static void resetQuotes() {
    quotes.set(0)
  }

  /** Ticket -2's first quote (and every other one after) stalls. */
  static java.util.concurrent.CompletableFuture<lawspec.runtime.LawSpecRuntime.Either<String, lawspec.data.Ticket>> hedgeQuote(
      lawspec.data.Ticket value0) {
    java.util.concurrent.Executor executor = value0.number() == -2 && quotes.incrementAndGet() % 2 == 1
        ? java.util.concurrent.CompletableFuture.delayedExecutor(600, java.util.concurrent.TimeUnit.MILLISECONDS)
        : java.util.concurrent.ForkJoinPool.commonPool()
    return java.util.concurrent.CompletableFuture.<LawSpecRuntime.Either<String, lawspec.data.Ticket>>supplyAsync(() -> new LawSpecRuntime.Right<String, lawspec.data.Ticket>(value0), executor)
  }

  /** Ticket -1's quote takes 600ms. */
  static java.util.concurrent.CompletableFuture<lawspec.runtime.LawSpecRuntime.Either<String, lawspec.data.Ticket>> fetchQuote(
      lawspec.data.Ticket value0) {
    java.util.concurrent.Executor executor = value0.number() == -1
        ? java.util.concurrent.CompletableFuture.delayedExecutor(600, java.util.concurrent.TimeUnit.MILLISECONDS)
        : java.util.concurrent.ForkJoinPool.commonPool()
    return java.util.concurrent.CompletableFuture.<LawSpecRuntime.Either<String, lawspec.data.Ticket>>supplyAsync(() -> new LawSpecRuntime.Right<String, lawspec.data.Ticket>(value0), executor)
  }
}
