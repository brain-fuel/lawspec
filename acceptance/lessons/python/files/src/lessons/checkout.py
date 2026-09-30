# User-owned LawSpec adapter.
import lawspec_data as data
import lawspec_schema as _schema


def checkout(value0):
    validated = validate(value0)
    if isinstance(validated, _schema.Left):
        return validated
    return _schema.Right(charge(validated.value))


def validate(value0):
    if len(value0.item) == 0:
        return _schema.Left(data.OrderProblemEmptyItem())
    if not 1 <= value0.quantity <= 20:
        return _schema.Left(data.OrderProblemBadQuantity())
    return _schema.Right(data.ValidOrderValidOrder(
        value0.item, data.QuantityQuantity(value0.quantity)))


def charge(value0):
    return data.ReceiptReceipt(value0.item, value0.quantity.value * 250)
