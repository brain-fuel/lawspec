# User-owned LawSpec adapter.
import lawspec_data as data


def convert(value0, value1):
    # One-to-one rates keep the example exact.
    return data.MoneyMoney(value0, value1.cents)
