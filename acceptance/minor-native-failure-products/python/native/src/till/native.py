# Application code the till's bindings name: its own money type, a till
# that is the production handler, and payments that raise its own
# exceptions.
from dataclasses import dataclass


@dataclass(frozen=True)
class Cash:
    cents: int


class CardDeclined(Exception):
    pass


class BadAmount(Exception):
    pass


class NativeTill:
    """A till that keeps what it takes."""

    def __init__(self):
        self.taken = 0

    def take(self, money: Cash) -> Cash:
        self.taken += money.cents
        return Cash(money.cents)

    def opening(self) -> Cash:
        return Cash(0)


def pay(till, cents: int) -> Cash:
    if cents < 0:
        raise BadAmount("negative")
    if cents > 1000:
        raise CardDeclined()
    return till.take(Cash(cents))
