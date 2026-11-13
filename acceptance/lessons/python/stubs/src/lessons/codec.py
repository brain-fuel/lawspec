# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument int32_1: Int32
# LawSpec result: Text
def formatQuantity(int32_1: int) -> str:
    raise NotImplementedError("formatQuantity")


# LawSpec argument text_1: Text
# LawSpec result: Int32
def parseQuantity(text_1: str) -> int:
    raise NotImplementedError("parseQuantity")
