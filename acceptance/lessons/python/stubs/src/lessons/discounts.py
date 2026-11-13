# User-owned LawSpec adapter.
import builtins as _builtins
import lawspec_data as data
import lawspec_schema as _schema
import lawspec_runtime as ls


# LawSpec argument int64_1: Int64
# LawSpec argument int32_1: Int32
# LawSpec result: Int64
def applyDiscount(int64_1: int, int32_1: int) -> int:
    raise NotImplementedError("applyDiscount")
