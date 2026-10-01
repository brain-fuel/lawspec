# User-owned LawSpec adapter.
import lawspec_data as data


def length(row):
    count = 0
    while isinstance(row, data.RowCell):
        count, row = count + 1, row.tail
    return count


def mirror(value0):
    if isinstance(value0, data.PerfectLeaf):
        return value0
    return data.PerfectNode(mirror(value0.right), mirror(value0.left))


def area(value0):
    return length(value0.rows) * length(value0.columns)


def duplicate(value0):
    return data.Halves(value0, value0)


def countPairs(value0):
    return data.Pairs(value0)


def dropFirst(value0):
    return data.Rest(value0)
