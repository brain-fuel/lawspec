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
