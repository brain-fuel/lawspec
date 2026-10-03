# User-owned LawSpec adapter: the workflow runtime under test.
import lawspec_data as data
import lawspec_runtime as ls
import lawspec_schema as _schema


def runtimeExponentialDelay(value0, value1, value2):
    return ls.retry_delay(('exponential', value0, value1, None), value2)


def runtimeLinearDelay(value0, value1, value2):
    return ls.retry_delay(('linear', value0, value1), value2)


def runtimeFibonacciDelay(value0, value1):
    return ls.retry_delay(('fibonacci', value0), value1)


def splitMix(value0, value1):
    random = ls.SplitMix64(value0)
    return [random.next() for _ in range(value1)]


def fullJitter(value0, value1):
    return ls.jittered('full', value1, 0, 0, ls.SplitMix64(value0))


def _waits(attempts, when):
    runtime = ls.WorkflowRuntime(ls.VirtualClock())
    retry = ls.Retry(('exponential', 100000, 2, None), attempts, 'none', when)
    ls.run_stage(runtime.context(), ls.StagePolicy('stage', retry),
                 lambda: ls.DataValue('Either::Left', (0,)))
    return [event[2] for event in runtime.trace if event[0] == 'sleep']


def retriedWaits(value0):
    return _waits(value0, None)


def rejectedWaits(value0):
    return _waits(value0, lambda error: False)


def limitedAt(value0):
    """Calls the generated workflow at each time under one runtime."""
    import lawspec_definitions.example.limits as workflows
    runtime = ls.WorkflowRuntime(ls.VirtualClock())
    admitted = []
    for time in value0:
        runtime.clock.time = time
        result = workflows.limited(runtime.context(), data.Ticket(0))
        admitted.append(isinstance(result, _schema.Right))
    return admitted


def compensationsFor(value0):
    """Books a ticket under a fresh runtime: the stages whose undos ran."""
    import lawspec_definitions.example.limits as workflows
    runtime = ls.WorkflowRuntime(ls.VirtualClock())
    workflows.book(runtime.context(), data.Ticket(value0))
    return [event[1] for event in runtime.trace if event[0] == 'compensate']


async def quoteTimedOut(value0):
    """Quotes a ticket under a runtime with the real clock: whether it timed out."""
    import lawspec_definitions.example.limits as workflows
    runtime = ls.WorkflowRuntime()
    result = workflows.quoted(runtime.context(), data.Ticket(value0))
    return isinstance(result, _schema.Left) and isinstance(result.value, data.QuotedErrorQuotedTimedOut)


async def quoteHedged(value0):
    """Quotes a ticket under a runtime with the real clock: whether it
    succeeded within 400ms, for ticket -2 through a hedged attempt."""
    import time
    import example.limits as quotes
    import lawspec_definitions.example.limits as workflows
    quotes.resetQuotes()
    runtime = ls.WorkflowRuntime()
    started = time.monotonic()
    result = workflows.hedged(runtime.context(), data.Ticket(value0))
    quick = time.monotonic() - started < 0.4
    hedged = any(event[0] == 'hedge' for event in runtime.trace)
    return isinstance(result, _schema.Right) and quick and (value0 != -2 or hedged)
