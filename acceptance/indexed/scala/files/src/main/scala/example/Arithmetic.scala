// User-owned LawSpec adapter.
package example

import lawspec.data.{Grid, Halves, Pairs, Perfect, Rest, Row}

object Arithmetic {
  private def length(row: Row): Long = row match {
    case Row.End => 0
    case Row.Cell(_, tail) => 1 + length(tail)
  }

  // (example.arithmetic::type::Perfect -> example.arithmetic::type::Perfect)
  def mirror(value0: lawspec.data.Perfect): lawspec.data.Perfect =
    value0 match {
      case leaf: Perfect.Leaf => leaf
      case Perfect.Node(left, right) => Perfect.Node(mirror(right), mirror(left))
    }

  // (example.arithmetic::type::Grid -> BigInt)
  def area(value0: lawspec.data.Grid): scala.math.BigInt =
    BigInt(length(value0.rows) * length(value0.columns))

  // (example.arithmetic::type::Row -> example.arithmetic::type::Halves)
  def duplicate(value0: lawspec.data.Row): lawspec.data.Halves =
    Halves(value0, value0)

  // (example.arithmetic::type::Row -> example.arithmetic::type::Pairs)
  def countPairs(value0: lawspec.data.Row): lawspec.data.Pairs =
    Pairs(value0)

  // (example.arithmetic::type::Row -> example.arithmetic::type::Rest)
  def dropFirst(value0: lawspec.data.Row): lawspec.data.Rest =
    Rest(value0)
}
