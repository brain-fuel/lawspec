# User-owned LawSpec adapter.


def priceInCents(value0: int) -> int:
    return value0 * (225 if value0 >= 10 else 250)
