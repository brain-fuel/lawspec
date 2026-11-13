# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument d: Int8
# LawSpec result: Bool
def isWeekend(d: int) -> bool:
    raise NotImplementedError("isWeekend")


# LawSpec argument int64_1: Int64
# LawSpec result: Int64
def roundToDollars(int64_1: int) -> int:
    raise NotImplementedError("roundToDollars")
