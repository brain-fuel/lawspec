# User-owned LawSpec adapter. A Duration is a datetime.timedelta.
from datetime import timedelta


def remaining(value0, value1):
    return max(value0 - value1, timedelta(0))
