# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument 0: example.harness::type::Order
# LawSpec result: Int32
def discount(value0: data.Order) -> int:
    # Ten percent off orders of more than ten items.
    return value0.total // 10 if value0.items > 10 else 0


# LawSpec argument 0: Int32
# LawSpec result: Int32
def roundCents(value0: int) -> int:
    # To the nearest ten cents, halves down: known to break a law.
    return (value0 + 4) // 10 * 10


# LawSpec argument 0: Int32
# LawSpec result: Bool
def book(
    ledger: "lawspec_abilities.example.harness.Ledger",
    value0: int
) -> bool:
    return ledger.accept(value0)


class LedgerHandler:
    """The native handler of Ledger: accept."""

    def accept(self, value0: _builtins.int) -> _builtins.bool:
        return value0 > 0
