// User-owned LawSpec adapter.
package example

import java.math.BigInteger
import lawspec.data.Expr
import lawspec.data.Pair
import lawspec.data.Shown

object Gadt {
    // Kotlin does not prune when-branches by type arguments, so these whens
    // end with else; the Boolean cases are never values of Expr<BigInteger>.
    fun evalNumber(value0: Expr<BigInteger>): BigInteger = when (value0) {
        is Expr.Number -> value0.value
        is Expr.Plus -> evalNumber(value0.left) + evalNumber(value0.right)
        else -> throw IllegalArgumentException("not an Expr<BigInteger>")
    }

    fun evalTruth(value0: Expr<Boolean>): Boolean = when (value0) {
        is Expr.Truth -> value0.value
        is Expr.Same -> evalNumber(value0.left) == evalNumber(value0.right)
        is Expr.Negate -> !evalTruth(value0.operand)
        else -> throw IllegalArgumentException("not an Expr<Boolean>")
    }

    fun evalPair(value0: Expr<Pair<BigInteger, Boolean>>): Pair<BigInteger, Boolean> = when (value0) {
        is Expr.Both<BigInteger, Boolean> -> Pair(evalNumber(value0.first), evalTruth(value0.second))
        else -> throw IllegalArgumentException("not an Expr<Pair<BigInteger, Boolean>>")
    }

    fun fold(value0: Expr<BigInteger>): Expr<BigInteger> = Expr.Number(evalNumber(value0))

    fun describe(value0: Shown): String = value0.witness
}
