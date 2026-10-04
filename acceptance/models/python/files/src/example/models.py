# User-owned LawSpec adapter: a stack and an atomic counter.
import itertools
import threading

import lawspec_data as data

_counters = {}
_ids = itertools.count()
_lock = threading.Lock()


def empty(value0):
    return data.StackEmpty()


def push(value0, value1):
    return data.PushFlow(data.StackPush(value0, value1))


def pop(value0):
    return data.PopFlow(value0.top, value0.rest)


def peek(value0):
    return data.PeekFlow(value0.top, value0)


def newCounter(value0):
    with _lock:
        identity = next(_ids)
        _counters[identity] = 0
    return data.Counter(identity)


async def increment(value0):
    with _lock:
        _counters[value0.id] += 1
        return _counters[value0.id]


async def decrement(value0):
    with _lock:
        _counters[value0.id] -= 1
        return _counters[value0.id]


async def read(value0):
    with _lock:
        return _counters[value0.id]
