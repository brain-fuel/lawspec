# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument 0: lessons.menu::type::Item
# LawSpec result: Int64
def priceOf(value0: data.Item) -> int:
    raise NotImplementedError("priceOf")


# LawSpec argument 0: Int64
# LawSpec argument 1: Int64
# LawSpec result: Int64
def cheapest(value0: int, value1: int) -> int:
    raise NotImplementedError("cheapest")
