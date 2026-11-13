# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument raw_order_1: lessons.checkout::type::RawOrder
# LawSpec result: Either (lessons.checkout::type::OrderProblem)
# (lessons.checkout::type::ValidOrder)
def validate(
    raw_order_1: data.RawOrder,
) -> _schema.Either[data.OrderProblem, data.ValidOrder]:
    raise NotImplementedError("validate")


# LawSpec argument valid_order_1: lessons.checkout::type::ValidOrder
# LawSpec result: lessons.checkout::type::Receipt
def charge(valid_order_1: data.ValidOrder) -> data.Receipt:
    raise NotImplementedError("charge")
