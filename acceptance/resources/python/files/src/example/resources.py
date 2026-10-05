# User-owned LawSpec adapters for the resources example.
import builtins as _builtins
import os
import socket
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


class Store:
    """An in-memory store. At most three may be open at once, so a store
    that is never closed is noticed."""
    open_count = 0

    def __init__(self):
        if Store.open_count >= 3:
            raise RuntimeError("too many open stores: one was never closed")
        Store.open_count += 1
        self.items = {}
        self.open = True

    def close(self):
        if self.open:
            self.open = False
            Store.open_count -= 1


# LawSpec argument 0: Unit
# LawSpec result: example.resources::type::Store
def openStore(value0: ls.Absence) -> _builtins.object:
    return Store()


# LawSpec argument 0: example.resources::type::Store
# LawSpec result: Unit
def closeStore(value0: _builtins.object) -> None:
    value0.close()


# LawSpec argument 0: example.resources::type::Store
# LawSpec result: Unit
def clearStore(value0: _builtins.object) -> None:
    value0.items.clear()


# LawSpec argument 0: example.resources::type::Store
# LawSpec argument 1: Int32
# LawSpec argument 2: Int32
# LawSpec result: Unit
def put(value0: _builtins.object, value1: int, value2: int) -> None:
    if not value0.open:
        raise RuntimeError("the store is closed")
    value0.items[value1] = value2


# LawSpec argument 0: example.resources::type::Store
# LawSpec argument 1: Int32
# LawSpec result: Maybe (Int32)
def get(value0: _builtins.object, value1: int) -> _schema.Maybe[_builtins.int]:
    if not value0.open:
        raise RuntimeError("the store is closed")
    if value1 in value0.items:
        return _schema.Just(value0.items[value1])
    return _schema.Nothing()


# LawSpec argument 0: example.resources::type::Store
# LawSpec result: Bool
def isOpen(value0: _builtins.object) -> bool:
    return value0.open


# LawSpec argument 0: Text
# LawSpec argument 1: Int32
# LawSpec result: Unit
def writeNote(value0: str, value1: int) -> None:
    with open(os.path.join(value0, "note.txt"), "w") as f:
        f.write(str(value1))


# LawSpec argument 0: Text
# LawSpec result: Maybe (Int32)
def readNote(value0: str) -> _schema.Maybe[_builtins.int]:
    path = os.path.join(value0, "note.txt")
    if not os.path.exists(path):
        return _schema.Nothing()
    with open(path) as f:
        return _schema.Just(int(f.read()))


# LawSpec argument 0: Int32
# LawSpec result: Bool
def canListen(value0: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", value0))
        s.listen()
        return True


# LawSpec argument 0: Int32
# LawSpec result: Unit
def setGreeting(value0: int) -> None:
    os.environ["LAWSPEC_EXAMPLE_GREETING"] = str(value0)


# LawSpec argument 0: Unit
# LawSpec result: Maybe (Int32)
def greeting(value0: ls.Absence) -> _schema.Maybe[_builtins.int]:
    value = os.environ.get("LAWSPEC_EXAMPLE_GREETING")
    return _schema.Nothing() if value is None else _schema.Just(int(value))
