# User-owned LawSpec adapter.
import lawspec_data as data


def evalNumber(value0):
    if isinstance(value0, data.ExprNumber):
        return value0.value
    return evalNumber(value0.value.left) + evalNumber(value0.value.right)


def evalTruth(value0):
    match value0:
        case data.ExprTruth(value=value):
            return value
        case data.ExprSame(value=data.Record772b3aa87ecd053fcced573681dbd8344f63903af98f493d5b458b00157f001e(left=left, right=right)):
            return evalNumber(left) == evalNumber(right)
        case data.ExprNegate(value=operand):
            return not evalTruth(operand)
    raise TypeError("not an Expr Bool")


def evalPair(value0):
    return data.Pair(evalNumber(value0.value.first), evalTruth(value0.value.second))


def fold(value0):
    return data.ExprNumber(evalNumber(value0))


def describe(value0):
    return value0.witness
