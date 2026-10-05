// User-owned LawSpec adapter: the approve workflow under the real clock.
package example;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import lawspec.data.ApproveError;
import lawspec.data.Order;
import lawspec.runtime.LawSpecRuntime;

public final class Approvals {
  /** Approves an order: whether it took less than 550ms. */
  public static CompletableFuture<Boolean> approvedQuickly(long value0) {
    return CompletableFuture.supplyAsync(() -> {
      var runtime = new LawSpecRuntime.WorkflowRuntime(null, 0);
      long started = System.nanoTime();
      lawspec.definitions.example.Workflows.approve(runtime.context(new HashMap<>()), new Order(value0));
      return System.nanoTime() - started < 550_000_000L;
    });
  }

  /** Approves an order: the messages of its failures, as reported. */
  public static CompletableFuture<List<String>> approvalErrors(long value0) {
    return CompletableFuture.supplyAsync(() -> {
      Workflows.finished.clear();
      var runtime = new LawSpecRuntime.WorkflowRuntime(null, 0);
      var result = lawspec.definitions.example.Workflows.approve(runtime.context(new HashMap<>()), new Order(value0));
      var messages = new ArrayList<String>();
      if (result instanceof LawSpecRuntime.Left<ApproveError, Order> left
          && left.value() instanceof ApproveError.ApproveFailures failures) {
        for (var failure : failures.error()) {
          if (failure instanceof ApproveError.ApproveCheckStockFailed stock) messages.add(stock.error());
          if (failure instanceof ApproveError.ApproveCheckCreditFailed credit) messages.add(credit.error());
        }
      }
      return messages;
    });
  }
}
