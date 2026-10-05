# User-owned LawSpec adapters for the tables example.
import lawspec_runtime as ls


# LawSpec argument 0: Int32
# LawSpec argument 1: Int32
# LawSpec result: Int32
def shippingCost(value0: int, value1: int) -> int:
    return value0 * value1 + 5 * value0


# LawSpec argument 0: Int32
# LawSpec result: Text
def label(value0: int) -> str:
    return f"parcel {value0}"
