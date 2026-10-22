# User-owned LawSpec adapter: the approve workflow under the real clock.
import time

import example.workflows as checks
import lawspec_data as data
import lawspec_runtime as ls
import lawspec_schema as _schema


async def approvedQuickly(value0):
    """Approves order value0: whether two of order -1's slow checks that started during this call overlapped in time. Run one after the other they cannot overlap, however loaded the machine is; checks other tests run at the same time never hide this call's own overlap."""
    import lawspec_definitions.example.workflows as workflows
    started = time.monotonic()
    workflows.approve(ls.WorkflowRuntime().context(), data.Order(value0))
    ran = [span for span in list(checks._spans) if span[0] >= started]
    return value0 != -1 or any(a[0] < b[1] and b[0] < a[1] for i, a in enumerate(ran) for b in ran[i + 1:])


async def approvalErrors(value0):
    """Approves order value0: the messages of its failures, as reported."""
    import lawspec_definitions.example.workflows as workflows
    checks._finished.clear()
    result = workflows.approve(ls.WorkflowRuntime().context(), data.Order(value0))
    if isinstance(result, _schema.Left):
        return [failure.error for failure in result.value.error]
    return []
