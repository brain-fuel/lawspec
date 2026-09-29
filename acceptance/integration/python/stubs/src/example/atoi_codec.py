# User-owned LawSpec adapter.
import lawspec_runtime as ls


# LawSpec argument 0: Int32
# LawSpec result: Text
def itoa(value0: int) -> str:
    raise NotImplementedError("itoa")


# LawSpec argument 0: Text
# LawSpec result: Int32
def atoi(value0: str) -> int:
    raise NotImplementedError("atoi")
