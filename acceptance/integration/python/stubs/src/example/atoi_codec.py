# User-owned LawSpec adapter.
import lawspec_runtime as ls


# LawSpec argument int32_1: Int32
# LawSpec result: Text
def itoa(int32_1: int) -> str:
    raise NotImplementedError("itoa")


# LawSpec argument text_1: Text
# LawSpec result: Int32
def atoi(text_1: str) -> int:
    raise NotImplementedError("atoi")
