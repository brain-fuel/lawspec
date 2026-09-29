def render(x: int) -> str:
    return str(x)
def referenceRender(x: int) -> str:
    return f"{x:d}"
def clamp(x: int) -> int:
    return max(0, x)
def referenceClamp(x: int) -> int:
    return 0 if x < 0 else x
