# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument 0: lessons.checkout::type::RawOrder
# LawSpec result: Either (lessons.checkout::type::OrderProblem)
# (lessons.checkout::type::Receipt)
def checkout(
    value0: data.RawOrder
) -> _schema.Either[data.OrderProblem, data.Receipt]:
    raise NotImplementedError("checkout")


# LawSpec argument 0: lessons.checkout::type::RawOrder
# LawSpec result: Either (lessons.checkout::type::OrderProblem)
# (lessons.checkout::type::ValidOrder)
def validate(
    value0: data.RawOrder
) -> _schema.Either[data.OrderProblem, data.ValidOrder]:
    raise NotImplementedError("validate")


# LawSpec argument 0: lessons.checkout::type::ValidOrder
# LawSpec result: lessons.checkout::type::Receipt
def charge(value0: data.ValidOrder) -> data.Receipt:
    raise NotImplementedError("charge")
