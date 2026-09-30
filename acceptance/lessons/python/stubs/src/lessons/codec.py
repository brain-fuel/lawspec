# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument 0: Int32
# LawSpec result: Text
def formatQuantity(value0: int) -> str:
    raise NotImplementedError("formatQuantity")


# LawSpec argument 0: Text
# LawSpec result: Int32
def parseQuantity(value0: str) -> int:
    raise NotImplementedError("parseQuantity")
