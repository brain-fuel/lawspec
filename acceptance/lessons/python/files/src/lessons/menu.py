# User-owned LawSpec adapter.
import lawspec_data as data


def priceOf(value0: data.Item) -> int:
    if isinstance(value0, data.ItemEspresso):
        return 250
    if isinstance(value0, data.ItemLatte):
        return 350
    return 300


def cheapest(value0: int, value1: int) -> int:
    return min(value0, value1)
