// User-owned LawSpec adapter.
package example

import java.math.BigInteger
import lawspec.data.Grid
import lawspec.data.Halves
import lawspec.data.Pairs
import lawspec.data.Perfect
import lawspec.data.Rest
import lawspec.data.Row

object Arithmetic {
    private fun length(row: Row): Long = when (row) {
        Row.End -> 0
        is Row.Cell -> 1 + length(row.tail)
    }

    fun mirror(value0: Perfect): Perfect = when (value0) {
        is Perfect.Leaf -> value0
        is Perfect.Node -> Perfect.Node(mirror(value0.right), mirror(value0.left))
    }

    fun area(value0: Grid): BigInteger = BigInteger.valueOf(length(value0.rows) * length(value0.columns))

    fun duplicate(value0: Row): Halves = Halves(value0, value0)

    fun countPairs(value0: Row): Pairs = Pairs(value0)

    fun dropFirst(value0: Row): Rest = Rest(value0)
}
