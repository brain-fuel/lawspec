// User-owned LawSpec adapter.
package example

import java.math.BigInteger
import lawspec.data.Expr
import lawspec.data.Pair
import lawspec.data.Shown

@groovy.transform.CompileStatic
final class Gadt {
  // Only the number cases implement Expr<Number>, so a number is one
  // of them.
  static BigInteger evalNumber(Expr<Number> value0) {
    if (value0 instanceof Expr.Plus plus) return evalNumber(plus.value().left()).add(evalNumber(plus.value().right()))
    new BigInteger(((Expr.Number) value0).value().toString())
  }

  static boolean evalTruth(Expr<Boolean> value0) {
    if (value0 instanceof Expr.Same same) return evalNumber(same.value().left()) == evalNumber(same.value().right())
    if (value0 instanceof Expr.Negate negate) return !evalTruth(negate.value())
    ((Expr.Truth) value0).value()
  }

  static Pair<Number, Boolean> evalPair(Expr<Pair<Number, Boolean>> value0) {
    var both = (Expr.Both<Number, Boolean>) value0
    new Pair<>(evalNumber(both.value().first()), evalTruth(both.value().second()))
  }

  static Expr<Number> fold(Expr<Number> value0) {
    return new Expr.Number(evalNumber(value0))
  }

  static String describe(Shown value0) {
    return value0.witness()
  }
}
