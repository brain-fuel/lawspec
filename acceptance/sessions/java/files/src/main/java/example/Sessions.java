// User-owned LawSpec adapter: adding through a server process, over the
// typed channel ends generated from the Serve and Hire protocols.
package example;

import java.math.BigInteger;
import java.util.concurrent.CompletableFuture;
import lawspec.runtime.LawSpecRuntime;
import lawspec.sessions.Hire;
import lawspec.sessions.Serve;

public final class Sessions {
  // The server: receive two numbers, send their sum.
  private static void serve(Serve.First.ReceiveInt32Step1 server) {
    var a = server.receive();
    var b = a.next().receive();
    b.next().send((long) a.value() + b.value());
  }

  // The client: send both numbers, receive the sum.
  private static long ask(Serve.Second.SendInt32Step1 client, int a, int b) {
    var afterA = client.send(a);
    var afterB = afterA.send(b);
    return afterB.receive().value();
  }

  public static CompletableFuture<Number> add(int value0, int value1) {
    return CompletableFuture.supplyAsync(() -> addNow(value0, value1));
  }

  private static Number addNow(int value0, int value1) {
    var ends = Serve.open();
    var server = LawSpecRuntime.spawn(() -> serve(ends.first()));
    long sum = ask(ends.second(), value0, value1);
    server.join();
    return BigInteger.valueOf(sum);
  }

  // A manager is handed the server's end over a Hire channel and serves it.
  public static CompletableFuture<Number> addHired(int value0, int value1) {
    return CompletableFuture.supplyAsync(() -> addHiredNow(value0, value1));
  }

  private static Number addHiredNow(int value0, int value1) {
    var serve = Serve.open();
    var hire = Hire.open();
    var manager = LawSpecRuntime.spawn(() -> serve(hire.second().receive().value()));
    hire.first().send(serve.first());
    long sum = ask(serve.second(), value0, value1);
    manager.join();
    return BigInteger.valueOf(sum);
  }
}
