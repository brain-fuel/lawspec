# User-owned LawSpec adapter: a queue, a set and a map shared between
# threads, each guarded by its own lock.
import collections
import itertools
import threading

import lawspec_data as data
import lawspec_schema as _schema

_ids = itertools.count()
_queues, _sets, _maps = {}, {}, {}


_registry = threading.Lock()


def _new(registry, value):
    with _registry:
        identity = next(_ids)
        registry[identity] = (threading.Lock(), value)
    return identity


def _get(registry, identity, empty):
    """A structure by its handle; generated tests may name one first."""
    with _registry:
        return registry.setdefault(identity, (threading.Lock(), empty()))


def newQueue(value0):
    return data.WorkQueue(_new(_queues, collections.deque()))


async def offer(value0, value1):
    lock, items = _get(_queues, value0.id, collections.deque)
    with lock:
        items.append(value1)


async def poll(value0):
    lock, items = _get(_queues, value0.id, collections.deque)
    with lock:
        return _schema.Just(items.popleft()) if items else _schema.Nothing()


async def queueSize(value0):
    lock, items = _get(_queues, value0.id, collections.deque)
    with lock:
        return len(items)


def newTags(value0):
    return data.Tags(_new(_sets, set()))


async def tag(value0, value1):
    lock, items = _get(_sets, value0.id, set)
    with lock:
        added = value1 not in items
        items.add(value1)
        return added


async def untag(value0, value1):
    lock, items = _get(_sets, value0.id, set)
    with lock:
        present = value1 in items
        items.discard(value1)
        return present


async def tagged(value0, value1):
    lock, items = _get(_sets, value0.id, set)
    with lock:
        return value1 in items


def newCache(value0):
    return data.Cache(_new(_maps, {}))


def _maybe(value):
    return _schema.Nothing() if value is None else _schema.Just(value)


async def store(value0, value1, value2):
    lock, entries = _get(_maps, value0.id, dict)
    with lock:
        previous = entries.get(value1)
        entries[value1] = value2
        return _maybe(previous)


async def fetch(value0, value1):
    lock, entries = _get(_maps, value0.id, dict)
    with lock:
        return _maybe(entries.get(value1))


async def evict(value0, value1):
    lock, entries = _get(_maps, value0.id, dict)
    with lock:
        return _maybe(entries.pop(value1, None))
