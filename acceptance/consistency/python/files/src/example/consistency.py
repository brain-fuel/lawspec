# User-owned LawSpec adapter: a page-view counter with one replica per thread.
import itertools
import threading

import lawspec_data as data

_replicas = {}
_ids = itertools.count()
_lock = threading.Lock()


def newViews(value0):
    with _lock:
        identity = next(_ids)
        _replicas[identity] = {}
    return data.Views(identity)


def hit(value0):
    with _lock:
        replicas = _replicas[value0.id]
        me = threading.get_ident()
        replicas[me] = replicas.get(me, 0) + 1
        return replicas[me]


def total(value0):
    with _lock:
        return sum(_replicas[value0.id].values())
