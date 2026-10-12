// User-owned LawSpec adapter: native code that gets the built-in abilities'
// handlers as arguments.
package example

object Builtins {
  // (Int32 -> lawspec.time::type::Duration)
  def elapsed(
    clock: lawspec.abilities.lawspec.Time.Clock,
    value0: scala.Int,
  ): scala.concurrent.duration.FiniteDuration = {
    val start = clock.now().value
    (1 to value0).foreach(_ => clock.now())
    scala.concurrent.duration.FiniteDuration(clock.now().value - start, java.util.concurrent.TimeUnit.MICROSECONDS)
  }

  // (Int32 -> Bytes)
  def token(
    secureRandom: lawspec.abilities.lawspec.Randomness.SecureRandom,
    value0: scala.Int,
  ): scala.IArray[scala.Byte] = secureRandom.secureBytes(value0)

  // (Int32 -> Bool)
  def listening(ports: lawspec.abilities.lawspec.Host.Ports, value0: scala.Int): scala.Boolean =
    try {
      val server = java.net.ServerSocket()
      try {
        server.setReuseAddress(true)
        server.bind(java.net.InetSocketAddress(java.net.InetAddress.getLoopbackAddress(), ports.freePort()))
        true
      } finally server.close()
    } catch { case _: java.io.IOException => false }

  // (Int32 -> Bool)
  def charge(log: lawspec.abilities.lawspec.Logging.Log, value0: scala.Int): scala.Boolean =
    if (value0 % 2 == 0) {
      log.logMessage(lawspec.data.LogLevel.Info, s"charged $value0")
      true
    } else false
}
