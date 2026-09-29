"""Native application strategies with ordinary Hypothesis shrinking."""

from decimal import Decimal

from hypothesis import strategies as st

from payments_domain import Euros, Price

samples = 0


def prices():
    def price(cents):
        global samples
        samples += 1
        return Price(major=Decimal((0, tuple(map(int, str(cents))), -2)),
                     unit=Euros())

    return st.integers(min_value=100, max_value=200).map(price)

scalar_samples = 0


def small_integers():
    def counted(value):
        global scalar_samples
        scalar_samples += 1
        return value

    return st.integers(min_value=6, max_value=20).map(counted)


def units():
    raise AssertionError("finite Unit enumeration must not call its factory")
