// User-owned LawSpec adapter.
package example

import lawspec.data.{Expr, Pair, Shown}

object Gadt {
  // Scala 3 refines the GADT's type argument in each case, so a match on an
  // Expr[BigInt] only needs the cases that build one.
  // (example.gadt::type::Expr (BigInt) -> BigInt)
  def evalNumber(value0: lawspec.data.Expr[scala.math.BigInt]): scala.math.BigInt =
    value0 match {
      case Expr.Number(value) => value
      case Expr.Plus(lawspec.data.PlusDetails(left, right)) => evalNumber(left) + evalNumber(right)
    }

  // (example.gadt::type::Expr (Bool) -> Bool)
  def evalTruth(value0: lawspec.data.Expr[scala.Boolean]): scala.Boolean =
    value0 match {
      case Expr.Truth(value) => value
      case Expr.Same(lawspec.data.PlusDetails(left, right)) => evalNumber(left) == evalNumber(right)
      case Expr.Negate(operand) => !evalTruth(operand)
    }

  // (example.gadt::type::Expr (example.gadt::type::Pair (BigInt) (Bool)) ->
  // example.gadt::type::Pair (BigInt) (Bool))
  def evalPair(
    value0: lawspec.data.Expr[lawspec.data.Pair[scala.math.BigInt, scala.Boolean]],
  ): lawspec.data.Pair[scala.math.BigInt, scala.Boolean] =
    value0 match {
      case Expr.Both(lawspec.data.BothDetails(first, second)) => Pair(evalNumber(first), evalTruth(second))
    }

  // (example.gadt::type::Expr (BigInt) -> example.gadt::type::Expr (BigInt))
  def fold(value0: lawspec.data.Expr[scala.math.BigInt]): lawspec.data.Expr[scala.math.BigInt] =
    Expr.Number(evalNumber(value0))

  // (example.gadt::type::Shown -> Text)
  def describe(value0: lawspec.data.Shown): java.lang.String = value0.witness
}
