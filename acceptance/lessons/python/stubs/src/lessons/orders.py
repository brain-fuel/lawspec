# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument 0: lessons.orders::type::Drink
# LawSpec result: Int64
def price(value0: data.Drink) -> int:
    raise NotImplementedError("price")
