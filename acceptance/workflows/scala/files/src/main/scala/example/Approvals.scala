// User-owned LawSpec adapter: the approve workflow under the real clock.
package example

import lawspec.data.ApproveError
import lawspec.data.Order
import lawspec.runtime.LawSpecRuntime
import scala.concurrent.{ExecutionContext, Future, blocking}
import scala.jdk.CollectionConverters.*

object Approvals {
  private given ExecutionContext = ExecutionContext.global

  // Approves an order: whether two of order -1's slow checks that started
  // during this call overlapped in time. Run one after the other they cannot
  // overlap, however loaded the machine is.
  def approvedQuickly(value0: Long): Future[Boolean] = Future {
    blocking {
      val runtime = LawSpecRuntime.WorkflowRuntime(null, 0)
      val started = System.nanoTime()
      lawspec.definitions.example.Workflows.approve(runtime.context(java.util.HashMap()), Order(value0))
      value0 != -1L || Workflows.overlapped(started)
    }
  }

  // Approves an order: the messages of its failures, as reported.
  def approvalErrors(value0: Long): Future[List[String]] = Future {
    blocking {
      Workflows.finished.clear()
      val runtime = LawSpecRuntime.WorkflowRuntime(null, 0)
      val result = lawspec.definitions.example.Workflows.approve(runtime.context(java.util.HashMap()), Order(value0))
      val failures = result match {
        case Left(ApproveError.ApproveFailures(errors)) => errors
        case _ => List()
      }
      failures.flatMap {
        case ApproveError.ApproveCheckStockFailed(error) => Some(error)
        case ApproveError.ApproveCheckCreditFailed(error) => Some(error)
        case _ => None
      }
    }
  }
}
