# User-owned LawSpec adapter.
import lawspec_data as data


def push(value0, value1):
    return data.PushFlow(data.StackPush(data.Record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be(top=value0, rest=value1)))


def pop(value0):
    return data.PopFlow(value0.value.top, value0.value.rest)


def peek(value0):
    return data.PeekFlow(value0.value.top, value0)
