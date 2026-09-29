def validPort(x: int) -> bool:
    return x >= 1 and x <= 65535
def render(x: int) -> str:
    if not validPort(x):
        raise ValueError("invalid port")
    return str(x)
def parse(x: str) -> int:
    return int(x)
