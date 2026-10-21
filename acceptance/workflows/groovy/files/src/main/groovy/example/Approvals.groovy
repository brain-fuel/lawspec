// User-owned LawSpec adapter: the approve workflow under the real clock.
package example

import java.util.ArrayList
import java.util.HashMap
import java.util.List
import java.util.concurrent.CompletableFuture
import lawspec.data.ApproveError
import lawspec.data.Order
import lawspec.runtime.LawSpecRuntime

@groovy.transform.CompileStatic
final class Approvals {
  /**
   * Approves an order: whether two of order -1's slow checks that started
   * during this call overlapped in time. Run one after the other they cannot
   * overlap, however loaded the machine is.
   */
  static CompletableFuture<Boolean> approvedQuickly(long value0) {
    return CompletableFuture.supplyAsync(() -> {
      var runtime = new LawSpecRuntime.WorkflowRuntime(null, 0)
      long started = System.nanoTime()
      lawspec.definitions.example.Workflows.approve(runtime.context(new HashMap<>()), new Order(value0))
      return value0 != -1L || Workflows.overlapped(started)
    })
  }

  /** Approves an order: the messages of its failures, as reported. */
  static CompletableFuture<List<String>> approvalErrors(long value0) {
    return CompletableFuture.<List<String>>supplyAsync(() -> {
      Workflows.finished.clear()
      var runtime = new LawSpecRuntime.WorkflowRuntime(null, 0)
      var result = lawspec.definitions.example.Workflows.approve(runtime.context(new HashMap<>()), new Order(value0))
      var messages = new ArrayList<String>()
      // Groovy 5 compiles instanceof bindings in a lambda's && to code the
      // JVM rejects, so this tests and casts.
      Object problem = result instanceof LawSpecRuntime.Left ? ((LawSpecRuntime.Left) result).value() : null
      if (problem instanceof ApproveError.ApproveFailures) {
        for (var failure : ((ApproveError.ApproveFailures) problem).error()) {
          if (failure instanceof ApproveError.ApproveCheckStockFailed) messages.add(((ApproveError.ApproveCheckStockFailed) failure).error())
          if (failure instanceof ApproveError.ApproveCheckCreditFailed) messages.add(((ApproveError.ApproveCheckCreditFailed) failure).error())
        }
      }
      return messages
    })
  }
}
