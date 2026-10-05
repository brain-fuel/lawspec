// User-owned LawSpec adapter: the approve workflow under the real clock.
package example

import lawspec.data.ApproveError
import lawspec.data.Order
import lawspec.runtime.LawSpecRuntime

object Approvals {
    // Approves an order: whether it took less than 550ms.
    suspend fun approvedQuickly(value0: Long): Boolean {
        val runtime = LawSpecRuntime.WorkflowRuntime(null, 0)
        val started = System.nanoTime()
        lawspec.definitions.example.Workflows.approve(runtime.context(HashMap()), Order(value0))
        return System.nanoTime() - started < 550_000_000L
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
