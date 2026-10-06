# User-owned LawSpec adapter: native code that gets the built-in abilities'
# handlers as arguments.
import socket
import lawspec_runtime as ls


# LawSpec argument 0: Int32
# LawSpec result: lawspec.time::type::Duration
def elapsed(clock: "lawspec_abilities.lawspec.time.Clock", value0: int) -> ls.timedelta:
    start = clock.now()
    for _ in range(value0):
        clock.now()
    return ls.timedelta(microseconds=clock.now().value - start.value)


# LawSpec argument 0: Int32
# LawSpec result: Bytes
def token(secureRandom: "lawspec_abilities.lawspec.random.SecureRandom", value0: int) -> bytes:
    return secureRandom.secureBytes(value0)


# LawSpec argument 0: Int32
# LawSpec result: Bool
def listening(ports: "lawspec_abilities.lawspec.system.Ports", value0: int) -> bool:
    port = ports.freePort()
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen()
        return True


# LawSpec argument 0: Int32
# LawSpec result: Bool
def charge(log: "lawspec_abilities.lawspec.log.Log", value0: int) -> bool:
    import lawspec_data as data
    if value0 % 2 == 0:
        log.logMessage(data.LogLevelInfo(), f"charged {value0}")
        return True
    return False
