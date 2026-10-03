// User-owned LawSpec adapter. A Duration is a kotlin.time.Duration.
package example

import kotlin.time.Duration

object Durations {
    fun remaining(value0: Duration, value1: Duration): Duration =
        if (value1 >= value0) Duration.ZERO else value0 - value1
}
