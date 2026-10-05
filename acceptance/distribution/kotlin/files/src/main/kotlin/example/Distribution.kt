// User-owned LawSpec adapter: the wire encoding, and nodes talking over
// in-memory, TCP and HTTP transports.
package example

import java.math.BigInteger
import lawspec.actors.TallyActor
import lawspec.data.Pair
import lawspec.data.Tally
import lawspec.remote.LawSpecRemote
import lawspec.runtime.LawSpecRuntime
import lawspec.mailboxes.LedgerMailbox
import lawspec.sessions.Answering
import lawspec.sessions.Doubling
import lawspec.sessions.Handoff
import lawspec.sessions.Passing

object Distribution {
    fun encoded(value0: String, value1: BigInteger, value2: Int, value3: Int): List<String> =
        LawSpecRuntime.wireEncoded(value0, value1.toLong(), value2.toLong(), value3.toLong())

    fun roundTrips(value0: String, value1: BigInteger, value2: Int, value3: Int): Boolean =
        LawSpecRuntime.wireRoundTrips(value0, value1.toLong(), value2.toLong(), value3.toLong())

    suspend fun remoteShifted(value0: Int): Long {
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

    suspend fun remoteAdds(value0: Short): Long {
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

    suspend fun remoteDoubling(value0: Int): Long {
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

    suspend fun remoteLedger(value0: Int): Long {
        val here = LawSpecRuntime.Node(LawSpecRuntime.TcpTransport())
        val there = LawSpecRuntime.Node(LawSpecRuntime.TcpTransport())
        try {
            val ledger = LedgerMailbox.serve(there, "ledger")
            val sender = LedgerMailbox.connect(here, there.address + "/ledger")
            sender.send(value0.toLong())
            sender.send(value0.toLong())
            val timeout = java.time.Duration.ofSeconds(5)
            return ledger.receive(timeout) + ledger.receive(timeout)
        } finally {
            here.close()
            there.close()
        }
    }

    suspend fun remoteHandoff(value0: Int): Long {
        val here = LawSpecRuntime.Node(LawSpecRuntime.TcpTransport())
        val there = LawSpecRuntime.Node(LawSpecRuntime.TcpTransport())
        try {
            // A local conversation on this node; its first end goes to the other.
            val ends = Doubling.open()
            val worker = LawSpecRuntime.spawn(Runnable {
                val got = ends.second().receive()
                got.next().send(2L * got.value())
            })
            val giving = Handoff.listen(here, "handoff")
            val taking = Handoff.dial(there, here.address + "/handoff")
            giving.send(ends.first())
            val end = taking.receive().value()
            val reply = end.send(value0).receive()
            worker.join()
            return reply.value()
        } finally {
            there.close()
            here.close()
        }
    }

    suspend fun remoteHandoffOnward(value0: Int): Long {
        val network = LawSpecRuntime.MemoryNetwork((value0 and 0xFFFF).toLong(), 0.1, 0.1, 0.005)
        val (a, b, c, d) = listOf("a", "b", "c", "d").map { LawSpecRuntime.Node(network.transport(it)) }
        try {
            // A conversation between A and C, which sends at once; A's end moves to B, then
            // to D, and answers from there.
            val first = Answering.listen(a, "answering")
            val second = Answering.dial(c, a.address + "/answering").send(value0)
            val toB = Passing.listen(a, "to-b")
            val atB = Passing.dial(b, a.address + "/to-b")
            toB.send(first)
            val moved = atB.receive().value()
            val toD = Passing.listen(b, "to-d")
            val atD = Passing.dial(d, b.address + "/to-d")
            toD.send(moved)
            val end = atD.receive().value()
            // The end no longer needs A or B.
            a.close()
            b.close()
            val got = end.receive()
            got.next().send(2L * got.value())
            return second.receive().value()
        } finally {
            for (node in listOf(a, b, c, d)) node.close()
        }
    }
}
