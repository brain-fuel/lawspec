"""Application strategies retain ordinary Hypothesis shrinking."""

from decimal import Decimal

from hypothesis import strategies as st

from payments_domain import Euros, Price


def prices():
    def price(cents):
        digits = tuple(map(int, str(cents)))
        return Price(major=Decimal((0, digits, -2)), unit=Euros())

    return st.integers(min_value=100, max_value=200).map(price)
