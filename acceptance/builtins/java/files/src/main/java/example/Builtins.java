// User-owned LawSpec adapter: native code that gets the built-in abilities'
// handlers as arguments.
package example;

public final class Builtins {
  // (Int32 -> lawspec.time::type::Duration)
  public static java.time.Duration elapsed(lawspec.abilities.lawspec.Time.Clock clock, int value0) {
    long start = clock.now().value();
    for (int i = 0; i < value0; i++) clock.now();
    return java.time.Duration.ofNanos((clock.now().value() - start) * 1000L);
  }

  // (Int32 -> Bytes)
  public static byte[] token(
      lawspec.abilities.lawspec.Randomness.SecureRandom secureRandom, int value0) {
    return secureRandom.secureBytes(value0);
  }

  // (Int32 -> Bool)
  public static boolean listening(lawspec.abilities.lawspec.Host.Ports ports, int value0) {
    try (var server = new java.net.ServerSocket()) {
      server.setReuseAddress(true);
      server.bind(new java.net.InetSocketAddress(java.net.InetAddress.getLoopbackAddress(), ports.freePort()));
      return true;
    } catch (java.io.IOException failed) {
      return false;
    }
  }

  // (Int32 -> Bool)
  public static boolean charge(lawspec.abilities.lawspec.Logging.Log log, int value0) {
    if (value0 % 2 == 0) {
      log.logMessage(new lawspec.data.LogLevel.Info(), "charged " + value0);
      return true;
    }
    return false;
  }
}
