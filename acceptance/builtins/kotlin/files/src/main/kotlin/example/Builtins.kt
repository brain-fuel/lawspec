// User-owned LawSpec adapter: native code that gets the built-in abilities'
// handlers as arguments.
package example

import kotlin.time.Duration.Companion.microseconds

object Builtins {
    // (Int32 -> lawspec.time::type::Duration)
    fun elapsed(
        clock: lawspec.abilities.lawspec.Time.Clock,
        value0: kotlin.Int,
    ): kotlin.time.Duration {
        val start = clock.now().value
        repeat(value0) { clock.now() }
        return (clock.now().value - start).microseconds
    }

    // (Int32 -> Bytes)
    fun token(
        secureRandom: lawspec.abilities.lawspec.Randomness.SecureRandom,
        value0: kotlin.Int,
    ): kotlin.ByteArray = secureRandom.secureBytes(value0)

    // (Int32 -> Bool)
    fun listening(ports: lawspec.abilities.lawspec.Host.Ports, value0: kotlin.Int): kotlin.Boolean =
        try {
            java.net.ServerSocket().use { server ->
                server.reuseAddress = true
                server.bind(java.net.InetSocketAddress(java.net.InetAddress.getLoopbackAddress(), ports.freePort()))
                true
            }
        } catch (failed: java.io.IOException) {
            false
        }

    // (Int32 -> Bool)
    fun charge(log: lawspec.abilities.lawspec.Logging.Log, value0: kotlin.Int): kotlin.Boolean {
        if (value0 % 2 == 0) {
            log.logMessage(lawspec.data.LogLevel.Info, "charged $value0")
            return true
        }
        return false
    }
}
