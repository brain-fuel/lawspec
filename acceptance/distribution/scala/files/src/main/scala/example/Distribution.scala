// User-owned LawSpec adapter: the wire encoding, and nodes talking over
// in-memory, TCP and HTTP transports.
package example

import java.math.BigInteger
import lawspec.actors.TallyActor
import lawspec.data.{Pair, Tally}
import lawspec.mailboxes.LedgerMailbox
import lawspec.remote.LawSpecRemote
import lawspec.runtime.LawSpecRuntime
import lawspec.sessions.{Answering, Doubling, Handoff, Passing}
import scala.concurrent.Future
import scala.jdk.CollectionConverters.*
import scala.util.Try

object Distribution {
  // The blocking work runs on the caller's thread; a throw fails the future.
  private def done[A](body: => A): Future[A] = Future.fromTry(Try(body))

  // (Text -> (UInt64 -> (Int32 -> (Int32 -> List (Text)))))
  def encoded(
    value0: java.lang.String,
    value1: scala.math.BigInt,
    value2: scala.Int,
    value3: scala.Int,
  ): scala.collection.immutable.List[java.lang.String] =
    LawSpecRuntime.wireEncoded(value0, value1.toLong, value2.toLong, value3.toLong).asScala.toList

  // (Text -> (UInt64 -> (Int32 -> (Int32 -> Bool))))
  def roundTrips(
    value0: java.lang.String,
    value1: scala.math.BigInt,
    value2: scala.Int,
    value3: scala.Int,
  ): scala.Boolean =
    LawSpecRuntime.wireRoundTrips(value0, value1.toLong, value2.toLong, value3.toLong)

  // (Int32 -> Int64)
  def remoteShifted(value0: scala.Int): scala.concurrent.Future[scala.Long] = done {
    val network = LawSpecRuntime.MemoryNetwork((value0 & 0xFFFF).toLong, 0.2, 0.2, 0.0)
    val here = LawSpecRuntime.Node(network.transport("here"))
    val there = LawSpecRuntime.Node(network.transport("there"))
    try {
      LawSpecRemote.serve(there)
      val result = LawSpecRemote.evaluate(
        here, there.address, "example.distribution::shifted",
        LawSpecRuntime.Value("Int32", BigInteger.valueOf(value0.toLong)),
      )
      result.data().asInstanceOf[BigInteger].longValueExact()
    } finally {
      here.close()
      there.close()
    }
  }

  // (Unit -> example.distribution::type::Tally)
  def openTally(value0: scala.Unit): lawspec.data.Tally = Tally(0)

  // (example.distribution::type::Tally -> (UInt8 -> lawspec.collections::type::Pair (Int64)
  // (example.distribution::type::Tally)))
  def add(
    value0: lawspec.data.Tally,
    value1: scala.Short,
  ): lawspec.data.Pair[scala.Long, lawspec.data.Tally] = {
    val after = value0.count + value1
    Pair(after, Tally(after))
  }

  // (UInt8 -> Int64)
  def remoteAdds(value0: scala.Short): scala.concurrent.Future[scala.Long] = done {
    val server = LawSpecRuntime.Node(LawSpecRuntime.TcpTransport())
    val client = LawSpecRuntime.Node(LawSpecRuntime.TcpTransport())
    try {
      val address = TallyActor.start().serve(server, "tally")
      val tally = TallyActor.connect(client, address)
      tally.add(value0)
      tally.add(value0)
    } finally {
      client.close()
      server.close()
    }
  }

  // (Int32 -> Int64)
  def remoteDoubling(value0: scala.Int): scala.concurrent.Future[scala.Long] = done {
    val server = LawSpecRuntime.Node(LawSpecRuntime.HttpTransport())
    val client = LawSpecRuntime.Node(LawSpecRuntime.HttpTransport())
    try {
      val first = Doubling.listen(server, "doubling")
      val second = Doubling.dial(client, server.address + "/doubling")
      val worker = LawSpecRuntime.spawn((() => {
        val got = second.receive()
        got.next().send(2L * got.value())
        ()
      }): Runnable)
      val reply = first.send(value0).receive()
      worker.join()
      reply.value()
    } finally {
      client.close()
      server.close()
    }
  }

  private def ledger(value0: Int): Long = {
    val here = LawSpecRuntime.Node(LawSpecRuntime.TcpTransport())
    val there = LawSpecRuntime.Node(LawSpecRuntime.TcpTransport())
    try {
      val ledger = LedgerMailbox.serve(there, "ledger")
      val sender = LedgerMailbox.connect(here, there.address + "/ledger")
      sender.send(value0.toLong)
      sender.send(value0.toLong)
      val timeout = java.time.Duration.ofSeconds(5)
      val total = ledger.receive(timeout) + ledger.receive(timeout)
      // receive within: nothing more comes, so it gives None in time.
      if (ledger.receiveWithin(java.time.Duration.ofMillis(20)).isDefined) -1L else total
    } finally {
      here.close()
      there.close()
    }
  }

  // (Int32 -> Int64)
  def remoteLedger(value0: scala.Int): scala.concurrent.Future[scala.Long] = done(ledger(value0))

  // (Int32 -> Int64)
  def remoteHandoff(value0: scala.Int): scala.concurrent.Future[scala.Long] = done {
    val here = LawSpecRuntime.Node(LawSpecRuntime.TcpTransport())
    val there = LawSpecRuntime.Node(LawSpecRuntime.TcpTransport())
    try {
      // A local conversation on this node; its first end goes to the other.
      val ends = Doubling.open()
      val worker = LawSpecRuntime.spawn((() => {
        val got = ends.second().receive()
        got.next().send(2L * got.value())
        ()
      }): Runnable)
      val giving = Handoff.listen(here, "handoff")
      val taking = Handoff.dial(there, here.address + "/handoff")
      giving.send(ends.first())
      val end = taking.receive().value()
      val reply = end.send(value0).receive()
      worker.join()
      reply.value()
    } finally {
      there.close()
      here.close()
    }
  }

  // (Int32 -> Int64)
  def remoteHandoffOnward(value0: scala.Int): scala.concurrent.Future[scala.Long] = done {
    val network = LawSpecRuntime.MemoryNetwork((value0 & 0xFFFF).toLong, 0.1, 0.1, 0.005)
    val nodes = List("a", "b", "c", "d").map(name => LawSpecRuntime.Node(network.transport(name)))
    val List(a, b, c, d) = nodes: @unchecked
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
      second.receive().value()
    } finally {
      nodes.foreach(_.close())
    }
  }

  private def sealedNow(value0: Int): Boolean = {
    val name = "example.distribution::shifted"
    val digest = LawSpecRemote.digest(name).getBytes(java.nio.charset.StandardCharsets.UTF_8)
    val seen = List(false, true).map { insecure =>
      val network = LawSpecRuntime.MemoryNetwork((value0 & 0xFFFF).toLong, 0.0, 0.0, 0.0, true)
      def make(node: String): LawSpecRuntime.Transport =
        if (insecure) network.insecureTransportForTests(node) else network.transport(node)
      val here = LawSpecRuntime.Node(make("here"))
      val there = LawSpecRuntime.Node(make("there"))
      try {
        LawSpecRemote.serve(there)
        val result = LawSpecRemote.evaluate(
          here, there.address, name,
          LawSpecRuntime.Value("Int32", BigInteger.valueOf(value0.toLong)),
        )
        if (result.data().asInstanceOf[BigInteger].longValueExact() != value0 + 1000L) None
        else Some(insecure -> network.recorded().asScala.exists(contains(_, digest)))
      } finally {
        here.close()
        there.close()
      }
    }
    seen == List(Some(false -> false), Some(true -> true))
  }

  // A definition evaluated on another node: its request names the
  // definition's content hash, which shows on the wire only in the clear.
  // (Int32 -> Bool)
  def sealedOnTheWire(value0: scala.Int): scala.concurrent.Future[scala.Boolean] =
    done(sealedNow(value0))

  private def contains(haystack: Array[Byte], needle: Array[Byte]): Boolean =
    (0 to haystack.length - needle.length).exists(i => needle.indices.forall(j => haystack(i + j) == needle(j)))

  // (Text -> Bool)
  def handshakeAgrees(value0: java.lang.String): scala.Boolean = {
    val f = value0.split(" ", -1)
    f.length == 13 && lawspec.runtime.LawSpecNetwork.handshakeVector(
      f(0), f(1), f(2), f(3), f(4), f(5), f(6), f(7), f(8), f(9), f(10), f(11), f(12),
    )
  }
}
