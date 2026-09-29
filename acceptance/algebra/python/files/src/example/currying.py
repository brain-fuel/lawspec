def sumFour(a: int,b: int,c: int,d: int) -> int: return a+b+c+d
def format(prefix: str,enabled: bool,port: int,suffix: str) -> str: return prefix+(str(port) if enabled else "")+suffix
def referenceFormat(prefix: str,enabled: bool,port: int,suffix: str) -> str: return "".join([prefix,str(port) if enabled else "",suffix])
def trim(x: str) -> str: return x.strip()
