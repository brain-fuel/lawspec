# User-owned LawSpec adapter: adding through a server process, directly and
# through a hired manager, with the generated typed channel ends.
import lawspec_runtime as ls
import lawspec_sessions as sessions


def _serve(server):
    """Serves one sum on the first end of a Serve channel."""
    a, server = server.receive()
    b, server = server.receive()
    server.send(a + b)


def _ask(client, a, b):
    """Asks for a + b on the second end of a Serve channel."""
    client = client.send(a)
    client = client.send(b)
    total, _ = client.receive()
    return int(total)


def _manage(manager):
    """Receives a server's end over a Hire channel and serves it."""
    server, _ = manager.receive()
    _serve(server)


async def add(value0, value1):
    server, client = sessions.Serve.open()
    process = ls.spawn(_serve, server)
    total = _ask(client, value0, value1)
    process.join()
    return total


async def addHired(value0, value1):
    boss, manager = sessions.Hire.open()
    server, client = sessions.Serve.open()
    process = ls.spawn(_manage, manager)
    boss.send(server)
    total = _ask(client, value0, value1)
    process.join()
    return total
