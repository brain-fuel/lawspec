# User-owned LawSpec adapter.


def isWeekend(value0: int) -> bool:
    return value0 in (0, 6)


def roundToDollars(value0: int) -> int:
    # Truncate toward zero, so the most negative Int64 cannot overflow.
    return value0 - (abs(value0) % 100) * (1 if value0 >= 0 else -1)
