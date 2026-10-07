# User-owned LawSpec adapter: the wire encoding, and nodes talking over
# in-memory, TCP and HTTP transports.
import lawspec_data as data
import lawspec_runtime as ls


def encoded(value0, value1, value2, value3):
    return ls.wire_encoded(value0, value1, value2, value3)


def roundTrips(value0, value1, value2, value3):
    return ls.wire_round_trips(value0, value1, value2, value3)


async def remoteShifted(value0):
    import lawspec_remote

    network = ls.MemoryNetwork(seed=value0 & 0xFFFF, loss=0.2, duplicate=0.2)
    here, there = ls.Node(network.transport('here')), ls.Node(network.transport('there'))
    lawspec_remote.serve(there)
    return lawspec_remote.evaluate(here, there.address, 'example.distribution::shifted', value0)


def openTally(value0):
    return data.Tally(0)


def add(value0, value1):
    after = value0.count + value1
    return data.Pair(after, data.Tally(after))


async def remoteAdds(value0):
    from lawspec_actors import TallyActor

    server, client = ls.Node(ls.TcpTransport()), ls.Node(ls.TcpTransport())
    try:
        address = TallyActor.start().serve(server, 'tally')
        tally = TallyActor.connect(client, address)
        tally.add(value0)
        return tally.add(value0)
    finally:
        client.close()
        server.close()


async def remoteDoubling(value0):
    from lawspec_sessions import Doubling

    server, client = ls.Node(ls.HttpTransport()), ls.Node(ls.HttpTransport())
    try:
        first = Doubling.listen(server, 'doubling')
        second = Doubling.dial(client, server.address + '/doubling')

        def double():
            x, reply = second.receive()
            reply.send(2 * x)
        worker = ls.spawn(double)
        result, _ = first.send(value0).receive()
        worker.join()
        return result
    finally:
        client.close()
        server.close()


async def remoteLedger(value0):
    from lawspec_mailboxes import LedgerMailbox

    here, there = ls.Node(ls.TcpTransport()), ls.Node(ls.TcpTransport())
    try:
        ledger = LedgerMailbox.serve(there, 'ledger')
        sender = LedgerMailbox.connect(here, there.address + '/ledger')
        sender.send(value0)
        sender.send(value0)
        total = ledger.receive(5) + ledger.receive(5)
        # receive within: nothing more comes, so it gives None in time.
        if ledger.receive_within(ls.timedelta(milliseconds=20)) is not None:
            return -1
        return total
    finally:
        here.close()
        there.close()


async def remoteHandoff(value0):
    from lawspec_sessions import Doubling, Handoff

    here, there = ls.Node(ls.TcpTransport()), ls.Node(ls.TcpTransport())
    try:
        # A local conversation on this node; its first end goes to the other.
        first, second = Doubling.open()

        def double():
            x, reply = second.receive()
            reply.send(2 * x)
        worker = ls.spawn(double)
        giving = Handoff.listen(here, 'handoff')
        taking = Handoff.dial(there, here.address + '/handoff')
        giving.send(first)
        end, _ = taking.receive()
        result, _ = end.send(value0).receive()
        worker.join()
        return result
    finally:
        there.close()
        here.close()


async def remoteHandoffOnward(value0):
    from lawspec_sessions import Answering, Passing

    network = ls.MemoryNetwork(seed=value0 & 0xFFFF, loss=0.1, duplicate=0.1, delay=0.005)
    a, b, c, d = (ls.Node(network.transport(n)) for n in 'abcd')
    try:
        # A conversation between A and C, which sends at once; A's end moves
        # to B, then to D, and answers from there.
        first = Answering.listen(a, 'answering')
        second = Answering.dial(c, a.address + '/answering').send(value0)
        to_b = Passing.listen(a, 'to-b')
        at_b = Passing.dial(b, a.address + '/to-b')
        to_b.send(first)
        moved, _ = at_b.receive()
        to_d = Passing.listen(b, 'to-d')
        at_d = Passing.dial(d, b.address + '/to-d')
        to_d.send(moved)
        end, _ = at_d.receive()
        # The end no longer needs A or B.
        a.close()
        b.close()
        x, reply = end.receive()
        reply.send(2 * x)
        result, _ = second.receive()
        return result
    finally:
        for node in (a, b, c, d):
            node.close()


async def sealedOnTheWire(value0):
    # A definition evaluated on another node: its request names the
    # definition's content hash, which shows on the wire only in the clear.
    import lawspec_remote

    name = 'example.distribution::shifted'
    digest = lawspec_remote.digest(name).encode('utf-8')
    seen = {}
    for insecure in (False, True):
        network = ls.MemoryNetwork(seed=value0 & 0xFFFF, record=True)
        make = network.insecure_transport_for_tests if insecure else network.transport
        here, there = ls.Node(make('here')), ls.Node(make('there'))
        try:
            lawspec_remote.serve(there)
            if lawspec_remote.evaluate(here, there.address, name, value0) != value0 + 1000:
                return False
            seen[insecure] = any(digest in frame for frame in network.recorded)
        finally:
            here.close()
            there.close()
    return seen == {False: False, True: True}


def handshakeAgrees(value0):
    import lawspec_network

    return lawspec_network.handshake_vector(*value0.split(' '))
