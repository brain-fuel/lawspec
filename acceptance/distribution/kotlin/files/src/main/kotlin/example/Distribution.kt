// User-owned LawSpec adapter: the wire encoding, and nodes talking over
// in-memory, TCP and HTTP transports.
package example

import java.math.BigInteger
import lawspec.actors.TallyActor
import lawspec.data.Pair
import lawspec.data.Tally
import lawspec.remote.LawSpecRemote
import lawspec.runtime.LawSpecRuntime
import lawspec.sessions.Doubling

object Distribution {
    fun encoded(value0: String, value1: BigInteger, value2: Int, value3: Int): List<String> =
        LawSpecRuntime.wireEncoded(value0, value1.toLong(), value2.toLong(), value3.toLong())

    fun roundTrips(value0: String, value1: BigInteger, value2: Int, value3: Int): Boolean =
        LawSpecRuntime.wireRoundTrips(value0, value1.toLong(), value2.toLong(), value3.toLong())

    fun remoteShifted(value0: Int): Long {
        val network = LawSpecRuntime.MemoryNetwork((value0 and 0xFFFF).toLong(), 0.2, 0.2, 0.0)
        val here = LawSpecRuntime.Node(network.transport("here"))
        val there = LawSpecRuntime.Node(network.transport("there"))
        try {
            LawSpecRemote.serve(there)
            val result = LawSpecRemote.evaluate(
                here, there.address, "example.distribution::shifted",
                LawSpecRuntime.Value("Int32", BigInteger.valueOf(value0.toLong())),
            )
            return (result.data() as BigInteger).longValueExact()
        } finally {
            here.close()
            there.close()
        }
    }

    fun openTally(value0: Unit): Tally = Tally(0)

    fun add(value0: Tally, value1: Short): Pair<Long, Tally> {
        val after = value0.count + value1
        return Pair(after, Tally(after))
    }

    fun remoteAdds(value0: Short): Long {
        val server = LawSpecRuntime.Node(LawSpecRuntime.TcpTransport())
        val client = LawSpecRuntime.Node(LawSpecRuntime.TcpTransport())
        try {
            val address = TallyActor.start().serve(server, "tally")
            val tally = TallyActor.connect(client, address)
            tally.add(value0)
            return tally.add(value0)
        } finally {
            client.close()
            server.close()
        }
    }

    fun remoteDoubling(value0: Int): Long {
        val server = LawSpecRuntime.Node(LawSpecRuntime.HttpTransport())
        val client = LawSpecRuntime.Node(LawSpecRuntime.HttpTransport())
        try {
            val first = Doubling.listen(server, "doubling")
            val second = Doubling.dial(client, server.address + "/doubling")
            val worker = LawSpecRuntime.spawn(Runnable {
                val got = second.receive()
                got.next().send(2L * got.value())
            })
            val reply = first.send(value0).receive()
            worker.join()
            return reply.value()
        } finally {
            client.close()
            server.close()
        }
    }
}
