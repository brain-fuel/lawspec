# User-owned LawSpec adapter: the approve workflow under the real clock.
import time

import example.workflows as checks
import lawspec_data as data
import lawspec_runtime as ls
import lawspec_schema as _schema


async def approvedQuickly(value0):
    """Approves order value0: whether it took less than 550ms."""
    import lawspec_definitions.example.workflows as workflows
    started = time.monotonic()
    workflows.approve(ls.WorkflowRuntime().context(), data.Order(value0))
    return time.monotonic() - started < 0.55


async def approvalErrors(value0):
    """Approves order value0: the messages of its failures, as reported."""
    import lawspec_definitions.example.workflows as workflows
    checks._finished.clear()
    result = workflows.approve(ls.WorkflowRuntime().context(), data.Order(value0))
    if isinstance(result, _schema.Left):
        return [failure.error for failure in result.value.error]
    return []
