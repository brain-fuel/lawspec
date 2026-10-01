// User-owned LawSpec adapter.
package example

import java.math.BigInteger

object Collections {
    fun dedupe(value0: List<Int>): Set<Int> = value0.toSet()

    fun wordCounts(value0: List<String>): Map<String, BigInteger> =
        value0.groupingBy { it }.eachCount().mapValues { BigInteger.valueOf(it.value.toLong()) }

    fun fifo(value0: List<Byte>): ArrayDeque<Byte> = ArrayDeque(value0)

    // A Stack's top is its last item, as for addLast and removeLast.
    fun lifo(value0: List<Byte>): ArrayDeque<Byte> = ArrayDeque(value0)

    fun rotate(value0: ArrayDeque<Byte>): ArrayDeque<Byte> {
        val rotated = ArrayDeque(value0)
        if (rotated.isNotEmpty()) rotated.addLast(rotated.removeFirst())
        return rotated
    }

    // Lists compare by value, so they can be Set elements directly.
    fun distinctRows(value0: List<List<Byte>>): Set<List<Byte>> = value0.toSet()
}
