// User-owned LawSpec adapter.
package example;

import java.util.concurrent.CompletableFuture;

public final class Orders {
  private static int priceOf(String sku) {
    return sku.equals("free") ? 0 : sku.codePointCount(0, sku.length()) % 100;
  }

  public static CompletableFuture<Integer> price(String value0) {
    return CompletableFuture.supplyAsync(() -> priceOf(value0));
  }

  public static CompletableFuture<Integer> stock(String value0) {
    return CompletableFuture.supplyAsync(() -> value0.codePointCount(0, value0.length()));
  }

  public static int quote(String value0) {
    return priceOf(value0);
  }
}
