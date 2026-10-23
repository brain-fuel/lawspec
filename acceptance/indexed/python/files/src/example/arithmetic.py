# User-owned LawSpec adapter.
import lawspec_data as data


def length(row):
    count = 0
    while isinstance(row, data.RowCell):
        count, row = count + 1, row.value.tail
    return count


def mirror(value0):
    if isinstance(value0, data.PerfectLeaf):
        return value0
    return data.PerfectNode(data.NodeDetails(left=mirror(value0.value.right), right=mirror(value0.value.left)))


def area(value0):
    return length(value0.value.rows) * length(value0.value.columns)


def duplicate(value0):
    return data.Halves(data.HalvesDetails(front=value0, back=value0))


def countPairs(value0):
    return data.Pairs(value0)


def dropFirst(value0):
    return data.Rest(value0)
