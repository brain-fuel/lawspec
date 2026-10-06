# User-owned LawSpec adapter: native handlers for the shop's abilities, and
# a native adapter that fails through the runtime's Fail.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument 0: Int32
# LawSpec result: Int32
def refund(
    gateway: "lawspec_abilities.example.abilities.Gateway",
    value0: int
) -> int:
    if value0 > 100000:
        raise ls.Fail(data.PaymentErrorTooLarge())
    return gateway.capture(value0).cents


class JournalHandler:
    """The native handler of Journal: note."""

    def __init__(self) -> None:
        self.lines: list[str] = []

    def note(self, value0: _builtins.str) -> None:
        self.lines.append(value0)


class StoreInt32Handler:
    """The native handler of Store Int32: load, save."""

    def __init__(self) -> None:
        self.value = 0

    def load(self) -> _builtins.int:
        return self.value

    def save(self, value0: _builtins.int) -> None:
        self.value = value0


class StoreTextHandler:
    """The native handler of Store Text: load, save."""

    def __init__(self) -> None:
        self.value = ""

    def load(self) -> _builtins.str:
        return self.value

    def save(self, value0: _builtins.str) -> None:
        self.value = value0


class MeterHandler:
    """The native handler of Meter: reading."""

    def reading(self) -> _builtins.int:
        return 3
