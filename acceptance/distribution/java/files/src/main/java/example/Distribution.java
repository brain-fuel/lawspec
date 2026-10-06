// User-owned LawSpec adapter: the wire encoding, and nodes talking over
// in-memory, TCP and HTTP transports.
package example;

import java.math.BigInteger;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import lawspec.actors.TallyActor;
import lawspec.data.Pair;
import lawspec.data.Tally;
import lawspec.remote.LawSpecRemote;
import lawspec.runtime.LawSpecRuntime;
import lawspec.mailboxes.LedgerMailbox;
import lawspec.sessions.Answering;
import lawspec.sessions.Doubling;
import lawspec.sessions.Handoff;
import lawspec.sessions.Passing;

public final class Distribution {
  public static List<String> encoded(String value0, BigInteger value1, int value2, int value3) {
    return LawSpecRuntime.wireEncoded(value0, value1.longValue(), value2, value3);
  }

  public static boolean roundTrips(String value0, BigInteger value1, int value2, int value3) {
    return LawSpecRuntime.wireRoundTrips(value0, value1.longValue(), value2, value3);
  }

  public static CompletableFuture<Long> remoteShifted(int value0) {
    return CompletableFuture.supplyAsync(() -> remoteShiftedNow(value0));
  }

  private static long remoteShiftedNow(int value0) {
    var network = new LawSpecRuntime.MemoryNetwork(value0 & 0xFFFF, 0.2, 0.2, 0);
    var here = new LawSpecRuntime.Node(network.transport("here"));
    var there = new LawSpecRuntime.Node(network.transport("there"));
    try {
      LawSpecRemote.serve(there);
      var result =
          LawSpecRemote.evaluate(
              here,
              there.address,
              "example.distribution::shifted",
              new LawSpecRuntime.Value("Int32", BigInteger.valueOf(value0)));
      return ((BigInteger) result.data()).longValueExact();
    } finally {
      here.close();
      there.close();
    }
  }

  public static Tally openTally(LawSpecRuntime.Value value0) {
    return new Tally(0L);
  }

  public static Pair<Long, Tally> add(Tally value0, short value1) {
    long after = value0.count() + value1;
    return new Pair<>(after, new Tally(after));
  }

  public static CompletableFuture<Long> remoteAdds(short value0) {
    return CompletableFuture.supplyAsync(() -> remoteAddsNow(value0));
  }

  private static long remoteAddsNow(short value0) {
    var server = new LawSpecRuntime.Node(new LawSpecRuntime.TcpTransport());
    var client = new LawSpecRuntime.Node(new LawSpecRuntime.TcpTransport());
    try {
      var address = TallyActor.start().serve(server, "tally");
      var tally = TallyActor.connect(client, address);
      tally.add(value0);
      return tally.add(value0);
    } finally {
      client.close();
      server.close();
    }
  }

  public static CompletableFuture<Long> remoteDoubling(int value0) {
    return CompletableFuture.supplyAsync(() -> remoteDoublingNow(value0));
  }

  private static long remoteDoublingNow(int value0) {
    var server = new LawSpecRuntime.Node(new LawSpecRuntime.HttpTransport());
    var client = new LawSpecRuntime.Node(new LawSpecRuntime.HttpTransport());
    try {
      var first = Doubling.listen(server, "doubling");
      var second = Doubling.dial(client, server.address + "/doubling");
      var worker =
          LawSpecRuntime.spawn(
              () -> {
                var got = second.receive();
                got.next().send(2L * got.value());
              });
      var reply = first.send(value0).receive();
      worker.join();
      return reply.value();
    } finally {
      client.close();
      server.close();
    }
  }

  public static CompletableFuture<Long> remoteLedger(int value0) {
    return CompletableFuture.supplyAsync(() -> remoteLedgerNow(value0));
  }

  private static long remoteLedgerNow(int value0) {
    var here = new LawSpecRuntime.Node(new LawSpecRuntime.TcpTransport());
    var there = new LawSpecRuntime.Node(new LawSpecRuntime.TcpTransport());
    try {
      var ledger = LedgerMailbox.serve(there, "ledger");
      var sender = LedgerMailbox.connect(here, there.address + "/ledger");
      sender.send((long) value0);
      sender.send((long) value0);
      var timeout = java.time.Duration.ofSeconds(5);
      long total = ledger.receive(timeout) + ledger.receive(timeout);
      // receive within: nothing more comes, so it gives nothing in time.
      if (ledger.receiveWithin(java.time.Duration.ofMillis(20)).isPresent()) return -1;
      return total;
    } finally {
      here.close();
      there.close();
    }
  }

  public static CompletableFuture<Long> remoteHandoff(int value0) {
    return CompletableFuture.supplyAsync(() -> remoteHandoffNow(value0));
  }

  private static long remoteHandoffNow(int value0) {
    var here = new LawSpecRuntime.Node(new LawSpecRuntime.TcpTransport());
    var there = new LawSpecRuntime.Node(new LawSpecRuntime.TcpTransport());
    try {
      // A local conversation on this node; its first end goes to the other.
      var ends = Doubling.open();
      var worker =
          LawSpecRuntime.spawn(
              () -> {
                var got = ends.second().receive();
                got.next().send(2L * got.value());
              });
      var giving = Handoff.listen(here, "handoff");
      var taking = Handoff.dial(there, here.address + "/handoff");
      giving.send(ends.first());
      var end = taking.receive().value();
      var reply = end.send(value0).receive();
      worker.join();
      return reply.value();
    } finally {
      there.close();
      here.close();
    }
  }

  public static CompletableFuture<Long> remoteHandoffOnward(int value0) {
    return CompletableFuture.supplyAsync(() -> remoteHandoffOnwardNow(value0));
  }

  private static long remoteHandoffOnwardNow(int value0) {
    var network = new LawSpecRuntime.MemoryNetwork(value0 & 0xFFFF, 0.1, 0.1, 0.005);
    var a = new LawSpecRuntime.Node(network.transport("a"));
    var b = new LawSpecRuntime.Node(network.transport("b"));
    var c = new LawSpecRuntime.Node(network.transport("c"));
    var d = new LawSpecRuntime.Node(network.transport("d"));
    try {
      // A conversation between A and C, which sends at once; A's end moves to B, then to D, and
      // answers from there.
      var first = Answering.listen(a, "answering");
      var second = Answering.dial(c, a.address + "/answering").send(value0);
      var toB = Passing.listen(a, "to-b");
      var atB = Passing.dial(b, a.address + "/to-b");
      toB.send(first);
      var moved = atB.receive().value();
      var toD = Passing.listen(b, "to-d");
      var atD = Passing.dial(d, b.address + "/to-d");
      toD.send(moved);
      var end = atD.receive().value();
      // The end no longer needs A or B.
      a.close();
      b.close();
      var got = end.receive();
      got.next().send(2L * got.value());
      return second.receive().value();
    } finally {
      for (var node : List.of(a, b, c, d)) node.close();
    }
  }

  public static CompletableFuture<Boolean> sealedOnTheWire(int value0) {
    return CompletableFuture.supplyAsync(() -> sealedOnTheWireNow(value0));
  }

  // A definition evaluated on another node: its request names the
  // definition's content hash, which shows on the wire only in the clear.
  private static boolean sealedOnTheWireNow(int value0) {
    String name = "example.distribution::shifted";
    byte[] digest = LawSpecRemote.digest(name).getBytes(java.nio.charset.StandardCharsets.UTF_8);
    boolean[] seen = new boolean[2];
    for (int run = 0; run < 2; run++) {
      boolean insecure = run == 1;
      var network = new LawSpecRuntime.MemoryNetwork(value0 & 0xFFFF, 0, 0, 0, true);
      var here = new LawSpecRuntime.Node(insecure ? network.insecureTransportForTests("here") : network.transport("here"));
      var there = new LawSpecRuntime.Node(insecure ? network.insecureTransportForTests("there") : network.transport("there"));
      try {
        LawSpecRemote.serve(there);
        var result =
            LawSpecRemote.evaluate(
                here, there.address, name, new LawSpecRuntime.Value("Int32", BigInteger.valueOf(value0)));
        if (((BigInteger) result.data()).longValueExact() != value0 + 1000L) return false;
        for (var frame : network.recorded()) if (contains(frame, digest)) seen[run] = true;
      } finally {
        here.close();
        there.close();
      }
    }
    return !seen[0] && seen[1];
  }

  private static boolean contains(byte[] haystack, byte[] needle) {
    outer:
    for (int i = 0; i + needle.length <= haystack.length; i++) {
      for (int j = 0; j < needle.length; j++) if (haystack[i + j] != needle[j]) continue outer;
      return true;
    }
    return false;
  }

  public static boolean handshakeAgrees(String value0) {
    var f = value0.split(" ", -1);
    if (f.length != 13) return false;
    return lawspec.runtime.LawSpecNetwork.handshakeVector(
        f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12]);
  }
}
