# User-owned LawSpec adapter.
import lawspec_data as data


def price(value0: data.Drink) -> int:
    base = 320 if isinstance(value0.size, data.SizeLarge) else 250
    return base + value0.shots * 60
