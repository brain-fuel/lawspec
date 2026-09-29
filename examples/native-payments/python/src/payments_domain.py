"""Application-owned payment types; no generated domain declarations."""

from dataclasses import dataclass
from decimal import Decimal
from fractions import Fraction

import lawspec_runtime as ls


class CurrencyCode:
    pass


@dataclass(frozen=True)
class Dollars(CurrencyCode):
    pass


@dataclass(frozen=True)
class Euros(CurrencyCode):
    pass


@dataclass(frozen=True)
class Pounds(CurrencyCode):
    pass


@dataclass(frozen=True, kw_only=True)
class Price:
    # Order differs deliberately; bridges must use the mapped field names.
    unit: CurrencyCode
    major: Decimal


class PaymentStatus:
    pass


@dataclass(frozen=True, kw_only=True)
class Settled(PaymentStatus):
    price: Price


@dataclass(frozen=True, kw_only=True)
class Rejected(PaymentStatus):
    explanation: str


def apply_fee(price):
    amount = ls.finite_decimal(Fraction(price.major) + Fraction(1, 5))
    return Price(major=amount, unit=price.unit)


def restore(payment):
    return payment


def store(payments):
    return payments
