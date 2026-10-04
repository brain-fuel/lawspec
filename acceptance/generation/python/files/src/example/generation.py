# User-owned LawSpec adapter: the portable generator under test.
import lawspec_runtime as ls


def generated(value0, value1, value2, value3):
    return ls.generated(value0, value1, value2, value3)


def shrunk(value0, value1, value2):
    return ls.shrunk(value0, value1, value2)
