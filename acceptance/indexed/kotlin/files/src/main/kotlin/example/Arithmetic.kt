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
        is Row.Cell -> 1 + length(row.value.tail)
    }

    fun mirror(value0: Perfect): Perfect = when (value0) {
        is Perfect.Leaf -> value0
        is Perfect.Node -> Perfect.Node(lawspec.data.Recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8(mirror(value0.value.right), mirror(value0.value.left)))
    }

    fun area(value0: Grid): BigInteger = BigInteger.valueOf(length(value0.value.rows) * length(value0.value.columns))

    fun duplicate(value0: Row): Halves = Halves(lawspec.data.Record90e2e86ad982c9c5e71a6cd286ab605cf2b3d771c37021fb930810c33933eb3d(value0, value0))

    fun countPairs(value0: Row): Pairs = Pairs(value0)

    fun dropFirst(value0: Row): Rest = Rest(value0)
}
