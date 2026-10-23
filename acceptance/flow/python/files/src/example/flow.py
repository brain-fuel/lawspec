# User-owned LawSpec adapter.
import lawspec_data as data


def push(value0, value1):
    return data.PushFlow(data.StackPush(data.PushDetails(top=value0, rest=value1)))


def pop(value0):
    return data.PopFlow(value0.value.top, value0.value.rest)


def peek(value0):
    return data.PeekFlow(value0.value.top, value0)
