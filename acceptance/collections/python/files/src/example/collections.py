# User-owned LawSpec adapter.
from collections import Counter, deque


def dedupe(value0):
    return frozenset(value0)


def wordCounts(value0):
    return dict(Counter(value0))


def fifo(value0):
    return deque(value0)


# A Stack's top is its last item, as for append and pop.
def lifo(value0):
    return deque(value0)


def rotate(value0):
    rotated = deque(value0)
    rotated.rotate(-1)
    return rotated


# Lists are not hashable, so a Set of lists is a tuple of distinct rows.
def distinctRows(value0):
    distinct = []
    for row in value0:
        if row not in distinct:
            distinct.append(row)
    return tuple(distinct)
