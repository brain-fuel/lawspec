# User-owned LawSpec adapter.
import lawspec_data as data
import lawspec_schema as _schema


def firstLine(value0):
    return value0.value[0]


def validateOrder(value0):
    if len(value0.id) == 0:
        return _schema.Left(data.OrderErrorInvalidOrderId())
    if not 1 <= value0.quantity <= 1000:
        return _schema.Left(data.OrderErrorInvalidQuantity())
    return _schema.Right(data.ValidatedOrder(
        data.OrderId(value0.id),
        data.UnitQuantity(value0.quantity)))


def priceOrder(value0):
    total = value0.quantity.value * 25
    if total > 20000:
        return _schema.Left(data.OrderErrorPriceTooHigh())
    return _schema.Right(data.PricedOrder(value0.id, value0.quantity, total))


def placeOrder(value0):
    validated = validateOrder(value0)
    if isinstance(validated, _schema.Left):
        return validated
    return priceOrder(validated.value)
