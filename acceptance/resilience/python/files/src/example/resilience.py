# User-owned LawSpec adapter: the workflow runtime under test.
import lawspec_runtime as ls


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
