# User-owned LawSpec adapter.
import lawspec_data as data


def replicate(value0, value1):
    result = data.VecVNil()
    for _ in range(value0):
        result = data.VecVCons(data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(head=value1, tail=result))
    return result


def append(value0, value1):
    if isinstance(value0, data.VecVNil):
        return value1
    return data.VecVCons(data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(head=value0.value.head, tail=append(value0.value.tail, value1)))


def zip(value0, value1):
    if isinstance(value0, data.VecVNil):
        return data.VecVNil()
    return data.VecVCons(data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(head=value1.value.head, tail=zip(value0.value.tail, value1.value.tail)))


def flatten(value0):
    if isinstance(value0, data.TreeTip):
        return data.VecVNil()
    right = data.VecVCons(data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(head=value0.value.value, tail=flatten(value0.value.right)))
    return append(flatten(value0.value.left), right)
