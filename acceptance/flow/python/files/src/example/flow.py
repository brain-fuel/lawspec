# User-owned LawSpec adapter.
import lawspec_data as data


def push(value0, value1):
    return data.PushFlow(data.StackPush(value0, value1))


def pop(value0):
    return data.PopFlow(value0.top, value0.rest)


def peek(value0):
    return data.PeekFlow(value0.top, value0)
