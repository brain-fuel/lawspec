# User-owned LawSpec adapter: Jobs is a thread-safe queue of the adapter's own.
import collections
import threading

import lawspec_schema as _schema


class JobQueue:
    """A deque guarded by a lock."""

    def __init__(self):
        self.items = collections.deque()
        self.lock = threading.Lock()


def newJobs(value0):
    return JobQueue()


def submit(value0, value1):
    with value0.lock:
        value0.items.append(value1)


def take(value0):
    with value0.lock:
        if not value0.items:
            return _schema.Nothing()
        return _schema.Just(value0.items.popleft())


def pending(value0):
    with value0.lock:
        return len(value0.items)
