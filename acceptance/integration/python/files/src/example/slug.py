def normalize(x: str) -> str:
    return x.replace(" ", "-")
def referenceNormalize(x: str) -> str:
    return "-".join(x.split(" "))
