// User-owned LawSpec adapter.
package example;

import java.math.BigInteger;
import lawspec.data.Expr;
import lawspec.data.Pair;
import lawspec.data.Shown;

public final class Gadt {
  // Only the number cases implement Expr<Number>, so the switch is
  // exhaustive without the Boolean cases.
  public static BigInteger evalNumber(Expr<Number> value0) {
    return switch (value0) {
      case Expr.Number number -> new BigInteger(number.value().toString());
      case Expr.Plus plus -> evalNumber(plus.value().left()).add(evalNumber(plus.value().right()));
    };
  }

  public static boolean evalTruth(Expr<Boolean> value0) {
    return switch (value0) {
      case Expr.Truth truth -> truth.value();
      case Expr.Same same -> evalNumber(same.value().left()).equals(evalNumber(same.value().right()));
      case Expr.Negate negate -> !evalTruth(negate.value());
    };
  }

  public static Pair<Number, Boolean> evalPair(Expr<Pair<Number, Boolean>> value0) {
    return switch (value0) {
      case Expr.Both<Number, Boolean> both ->
          new Pair<>(evalNumber(both.value().first()), evalTruth(both.value().second()));
    };
  }

  public static Expr<Number> fold(Expr<Number> value0) {
    return new Expr.Number(evalNumber(value0));
  }

  public static String describe(Shown value0) {
    return value0.witness();
  }
}
