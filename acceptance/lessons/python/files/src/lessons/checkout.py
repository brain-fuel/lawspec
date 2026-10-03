# User-owned LawSpec adapter.
import lawspec_data as data
import lawspec_schema as _schema


def validate(value0):
    if len(value0.item) == 0:
        return _schema.Left(data.OrderProblemEmptyItem())
    if not 1 <= value0.quantity <= 20:
        return _schema.Left(data.OrderProblemBadQuantity())
    return _schema.Right(data.ValidOrder(
        value0.item, data.Quantity(value0.quantity)))


def charge(value0):
    return data.Receipt(value0.item, value0.quantity.value * 250)
