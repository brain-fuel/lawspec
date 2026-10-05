// User-owned LawSpec adapter: the wire encoding, and nodes talking over
// in-memory, TCP and HTTP transports.
package example;

import java.math.BigInteger;
import java.util.List;
import lawspec.actors.TallyActor;
import lawspec.data.Pair;
import lawspec.data.Tally;
import lawspec.remote.LawSpecRemote;
import lawspec.runtime.LawSpecRuntime;
import lawspec.sessions.Doubling;

public final class Distribution {
  public static List<String> encoded(String value0, BigInteger value1, int value2, int value3) {
    return LawSpecRuntime.wireEncoded(value0, value1.longValue(), value2, value3);
  }

  public static boolean roundTrips(String value0, BigInteger value1, int value2, int value3) {
    return LawSpecRuntime.wireRoundTrips(value0, value1.longValue(), value2, value3);
  }

  public static long remoteShifted(int value0) {
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

  public static long remoteAdds(short value0) {
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

  public static long remoteDoubling(int value0) {
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
}
