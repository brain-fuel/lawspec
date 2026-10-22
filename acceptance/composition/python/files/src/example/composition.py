# User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
# share the case's Store.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


class Store:
    """An in-memory log store: each log's records, newest last."""

    def __init__(self) -> None:
        self.logs: dict[str, list[str]] = {}
        self.open = True


# LawSpec argument 0: Unit
# LawSpec result: example.composition::type::Store
def openStore(value0: ls.Absence) -> _builtins.object:
    return Store()


# LawSpec argument 0: example.composition::type::Store
# LawSpec result: Unit
def closeStore(value0: _builtins.object) -> None:
    value0.open = False


class LogsHandler:
    """The native handler of Logs: create, append."""

    def __init__(self, resource: _builtins.object) -> None:
        self.resource = resource

    def create(self, value0: _builtins.str) -> None:
        self.resource.logs[value0] = []

    def append(
        self,
        value0: _builtins.str,
        value1: _builtins.str,
    ) -> _builtins.int:
        if value0 not in self.resource.logs:
            raise ls.Fail(data.ProblemUnknownLog())
        if value1 == "":
            raise ls.Fail(data.ProblemEmptyRecord())
        records = self.resource.logs[value0]
        records.append(value1)
        return len(records) - 1


class ReaderHandler:
    """The native handler of Reader: size."""

    def __init__(self, resource: _builtins.object) -> None:
        self.resource = resource

    def size(self, value0: _builtins.str) -> _schema.Maybe[_builtins.int]:
        if value0 not in self.resource.logs:
            return _schema.Absent()
        return _schema.Present(len(self.resource.logs[value0]))


class WriterHandler:
    """The native handler of Writer: write, lastOffset."""

    def __init__(self, resource: _builtins.object) -> None:
        self.resource = resource
        self.last: _schema.Maybe[_builtins.int] = _schema.Absent()

    def write(
        self,
        value0: _builtins.str,
        value1: _builtins.str,
    ) -> _builtins.bool:
        records = self.resource.logs.get(value0)
        if records is None or value1 == "":
            return False
        records.append(value1)
        self.last = _schema.Present(len(records) - 1)
        return True

    def lastOffset(self) -> _schema.Maybe[_builtins.int]:
        return self.last
