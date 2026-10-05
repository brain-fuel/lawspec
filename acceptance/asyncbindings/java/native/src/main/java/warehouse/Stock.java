package warehouse;

import java.util.concurrent.CompletableFuture;

/**
 * Application code the warehouse adapters are bound to: some of it asynchronous, as a real service
 * client would be.
 */
public final class Stock {
  private Stock() {}

  private static int price(String sku) {
    return sku.equals("free") ? 0 : sku.codePointCount(0, sku.length()) % 100;
  }

  public static CompletableFuture<Integer> priceOf(String sku) {
    return CompletableFuture.supplyAsync(() -> price(sku));
  }

  public static int quoteOf(String sku) {
    return price(sku);
  }

  /** A stock count that several callers may change. */
  public static final class Shelf {
    private long total;

    public CompletableFuture<Void> restock(int amount) {
      return CompletableFuture.runAsync(() -> {
        synchronized (this) {
          total += amount;
        }
      });
    }

    public CompletableFuture<Long> count() {
      return CompletableFuture.supplyAsync(() -> {
        synchronized (this) {
          return total;
        }
      });
    }
  }
}
