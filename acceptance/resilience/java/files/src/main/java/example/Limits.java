// User-owned LawSpec adapter.
package example;

import lawspec.runtime.LawSpecRuntime;

public final class Limits {
  public static LawSpecRuntime.Either<String, lawspec.data.Ticket> admitTicket(lawspec.data.Ticket value0) {
    return new LawSpecRuntime.Right<>(value0);
  }

  public static LawSpecRuntime.Either<String, lawspec.data.Ticket> reserveSeat(lawspec.data.Ticket value0) {
    return new LawSpecRuntime.Right<>(value0);
  }

  public static LawSpecRuntime.Either<String, lawspec.data.Ticket> chargeCard(lawspec.data.Ticket value0) {
    if (value0.number() < 0) return new LawSpecRuntime.Left<>("declined");
    return new LawSpecRuntime.Right<>(value0);
  }

  public static boolean releaseSeat(lawspec.data.Ticket value0) {
    return true;
  }

  private static final java.util.concurrent.atomic.AtomicLong quotes = new java.util.concurrent.atomic.AtomicLong();

  public static void resetQuotes() {
    quotes.set(0);
  }

  /** Ticket -2's first quote (and every other one after) stalls. */
  public static java.util.concurrent.CompletableFuture<LawSpecRuntime.Either<String, lawspec.data.Ticket>> hedgeQuote(
      lawspec.data.Ticket value0) {
    java.util.concurrent.Executor executor = value0.number() == -2 && quotes.incrementAndGet() % 2 == 1
        ? java.util.concurrent.CompletableFuture.delayedExecutor(600, java.util.concurrent.TimeUnit.MILLISECONDS)
        : java.util.concurrent.ForkJoinPool.commonPool();
    return java.util.concurrent.CompletableFuture.supplyAsync(() -> new LawSpecRuntime.Right<>(value0), executor);
  }

  /** Ticket -1's quote takes 600ms. */
  public static java.util.concurrent.CompletableFuture<LawSpecRuntime.Either<String, lawspec.data.Ticket>> fetchQuote(
      lawspec.data.Ticket value0) {
    java.util.concurrent.Executor executor = value0.number() == -1
        ? java.util.concurrent.CompletableFuture.delayedExecutor(600, java.util.concurrent.TimeUnit.MILLISECONDS)
        : java.util.concurrent.ForkJoinPool.commonPool();
    return java.util.concurrent.CompletableFuture.supplyAsync(() -> new LawSpecRuntime.Right<>(value0), executor);
  }
}
