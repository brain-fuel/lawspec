// User-owned LawSpec adapter: the approve workflow under the real clock.
package example

import lawspec.data.ApproveError
import lawspec.data.Order
import lawspec.runtime.LawSpecRuntime

object Approvals {
    // Approves an order: whether two of order -1's slow checks that started
    // during this call overlapped in time. Run one after the other they
    // cannot overlap, however loaded the machine is.
    suspend fun approvedQuickly(value0: Long): Boolean {
        val runtime = LawSpecRuntime.WorkflowRuntime(null, 0)
        val started = System.nanoTime()
        lawspec.definitions.example.Workflows.approve(runtime.context(HashMap()), Order(value0))
        return value0 != -1L || Workflows.overlapped(started)
    }

    // Approves an order: the messages of its failures, as reported.
    suspend fun approvalErrors(value0: Long): List<String> {
        Workflows.finished.clear()
        val runtime = LawSpecRuntime.WorkflowRuntime(null, 0)
        val result = lawspec.definitions.example.Workflows.approve(runtime.context(HashMap()), Order(value0))
        val failures = ((result as? LawSpecRuntime.Left<*, *>)?.value() as? ApproveError.ApproveFailures)?.error ?: return listOf()
        return failures.mapNotNull {
            when (it) {
                is ApproveError.ApproveCheckStockFailed -> it.error
                is ApproveError.ApproveCheckCreditFailed -> it.error
                else -> null
            }
        }
    }
}
