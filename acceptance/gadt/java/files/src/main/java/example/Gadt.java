// User-owned LawSpec adapter.
package example;

import java.math.BigInteger;
import lawspec.data.Expr;
import lawspec.data.Pair;
import lawspec.data.Shown;

public final class Gadt {
  // Only the number cases implement Expr<BigInteger>, so the switch is
  // exhaustive without the Boolean cases.
  public static BigInteger evalNumber(Expr<BigInteger> value0) {
    return switch (value0) {
      case Expr.Number number -> number.value();
      case Expr.Plus plus -> evalNumber(plus.left()).add(evalNumber(plus.right()));
    };
  }

  public static boolean evalTruth(Expr<Boolean> value0) {
    return switch (value0) {
      case Expr.Truth truth -> truth.value();
      case Expr.Same same -> evalNumber(same.left()).equals(evalNumber(same.right()));
      case Expr.Negate negate -> !evalTruth(negate.operand());
    };
  }

  public static Pair<BigInteger, Boolean> evalPair(Expr<Pair<BigInteger, Boolean>> value0) {
    return switch (value0) {
      case Expr.Both<BigInteger, Boolean> both ->
          new Pair<>(evalNumber(both.first()), evalTruth(both.second()));
    };
  }

  public static Expr<BigInteger> fold(Expr<BigInteger> value0) {
    return new Expr.Number(evalNumber(value0));
  }

  public static String describe(Shown value0) {
    return value0.witness();
  }
}
