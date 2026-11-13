# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument item_1: lessons.menu::type::Item
# LawSpec result: Int64
def priceOf(item_1: data.Item) -> int:
    raise NotImplementedError("priceOf")


# LawSpec argument int64_1: Int64
# LawSpec argument int64_2: Int64
# LawSpec result: Int64
def cheapest(int64_1: int, int64_2: int) -> int:
    raise NotImplementedError("cheapest")
