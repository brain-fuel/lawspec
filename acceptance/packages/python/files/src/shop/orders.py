# User-owned LawSpec adapter.
import lawspec_data as data


def settlement(value0):
    if isinstance(value0, data.ShopOrdersCurrencyUsd):
        return data.ShopDomainCurrencyUsd()
    return data.ShopDomainCurrencyEur()


def lineTotal(value0):
    price = value0.price
    total = price.cents * value0.quantity.value
    return data.Money(price.currency, min(total, 100000000))


def cheaper(value0, value1):
    return min(value0, value1)


def roundDown(value0):
    # Truncate toward zero, like the other targets' remainder.
    remainder = abs(value0) % 100
    return value0 - remainder if value0 >= 0 else value0 + remainder
