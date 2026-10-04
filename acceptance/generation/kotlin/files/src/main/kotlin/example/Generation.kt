// User-owned LawSpec adapter: the portable generator under test.
package example

import java.math.BigInteger
import lawspec.runtime.LawSpecRuntime

object Generation {
    fun generated(value0: String, value1: BigInteger, value2: Int, value3: Int): List<String> =
        LawSpecRuntime.generated(value0, value1.toLong(), value2.toLong(), value3.toLong())

    fun shrunk(value0: String, value1: BigInteger, value2: Int): List<String> =
        LawSpecRuntime.shrunk(value0, value1.toLong(), value2.toLong())
}
