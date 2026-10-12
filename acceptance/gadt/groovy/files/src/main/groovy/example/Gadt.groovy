// User-owned LawSpec adapter.
package example

import java.math.BigInteger
import lawspec.data.Expr
import lawspec.data.Pair
import lawspec.data.Shown

@groovy.transform.CompileStatic
final class Gadt {
  // Only the number cases implement Expr<BigInteger>, so a number is one
  // of them.
  static BigInteger evalNumber(Expr<BigInteger> value0) {
    if (value0 instanceof Expr.Plus plus) return evalNumber(plus.left()).add(evalNumber(plus.right()))
    ((Expr.Number) value0).value()
  }

  static boolean evalTruth(Expr<Boolean> value0) {
    if (value0 instanceof Expr.Same same) return evalNumber(same.left()) == evalNumber(same.right())
    if (value0 instanceof Expr.Negate negate) return !evalTruth(negate.operand())
    ((Expr.Truth) value0).value()
  }

  static Pair<BigInteger, Boolean> evalPair(Expr<Pair<BigInteger, Boolean>> value0) {
    var both = (Expr.Both<BigInteger, Boolean>) value0
    new Pair<>(evalNumber(both.first()), evalTruth(both.second()))
  }

  static Expr<BigInteger> fold(Expr<BigInteger> value0) {
    return new Expr.Number(evalNumber(value0))
  }

  static String describe(Shown value0) {
    return value0.witness()
  }
}
