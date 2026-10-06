# User-owned LawSpec adapters for the matchers example.
import builtins as _builtins
import re
import lawspec_data as data


# LawSpec argument 0: List (Int32)
# LawSpec result: List (Int32)
def sortItems(
    value0: _builtins.list[_builtins.int]
) -> _builtins.list[_builtins.int]:
    return sorted(value0)


# LawSpec argument 0: List (Text)
# LawSpec result: List (Text)
def uniqueTags(
    value0: _builtins.list[_builtins.str]
) -> _builtins.list[_builtins.str]:
    seen = []
    for tag in value0:
        if tag not in seen:
            seen.append(tag)
    return seen


# LawSpec argument 0: Int32
# LawSpec argument 1: Int32
# LawSpec result: Float64
def average(value0: int, value1: int) -> float:
    return (value0 + value1) / 2


# LawSpec argument 0: Text
# LawSpec result: Text
def slug(value0: str) -> str:
    words = re.findall(r'[a-z0-9]+', value0.lower())
    return '-'.join(words)


# LawSpec argument 0: Int32
# LawSpec result: example.matchers::type::Order
def ship(value0: int) -> data.Order:
    return data.OrderShipped(value0, "post")
