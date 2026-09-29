# User-owned LawSpec adapter.
import lawspec_data as data


def replicate(value0, value1):
    result = data.VecVNil()
    for _ in range(value0):
        result = data.VecVCons(value1, result)
    return result


def append(value0, value1):
    if isinstance(value0, data.VecVNil):
        return value1
    return data.VecVCons(value0.head, append(value0.tail, value1))


def zip(value0, value1):
    if isinstance(value0, data.VecVNil):
        return data.VecVNil()
    return data.VecVCons(value1.head, zip(value0.tail, value1.tail))


def flatten(value0):
    if isinstance(value0, data.TreeTip):
        return data.VecVNil()
    right = data.VecVCons(value0.value, flatten(value0.right))
    return append(flatten(value0.left), right)
