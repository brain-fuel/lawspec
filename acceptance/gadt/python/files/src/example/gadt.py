# User-owned LawSpec adapter.
import lawspec_data as data


def evalNumber(value0):
    if isinstance(value0, data.ExprNumber):
        return value0.value
    return evalNumber(value0.left) + evalNumber(value0.right)


def evalTruth(value0):
    match value0:
        case data.ExprTruth(value=value):
            return value
        case data.ExprSame(left=left, right=right):
            return evalNumber(left) == evalNumber(right)
        case data.ExprNegate(operand=operand):
            return not evalTruth(operand)
    raise TypeError("not an Expr Bool")


def evalPair(value0):
    return data.Pair(evalNumber(value0.first), evalTruth(value0.second))


def fold(value0):
    return data.ExprNumber(evalNumber(value0))


def describe(value0):
    return value0.witness
