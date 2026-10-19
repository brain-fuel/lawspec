// User-owned LawSpec adapter.
package example

import lawspec.data.{Grid, Halves, Pairs, Perfect, Rest, Row}

object Arithmetic {
  private def length(row: Row): Long = row match {
    case Row.End => 0
    case Row.Cell(lawspec.data.Record3b011c4276dbdecc2735ac0f8fa7ce5517233cc5b302ba305baeed3dec2f677f(_, tail)) => 1 + length(tail)
  }

  // (example.arithmetic::type::Perfect -> example.arithmetic::type::Perfect)
  def mirror(value0: lawspec.data.Perfect): lawspec.data.Perfect =
    value0 match {
      case leaf: Perfect.Leaf => leaf
      case Perfect.Node(lawspec.data.Recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8(left, right)) => Perfect.Node(lawspec.data.Recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8(mirror(right), mirror(left)))
    }

  // (example.arithmetic::type::Grid -> BigInt)
  def area(value0: lawspec.data.Grid): scala.math.BigInt =
    BigInt(length(value0.value.rows) * length(value0.value.columns))

  // (example.arithmetic::type::Row -> example.arithmetic::type::Halves)
  def duplicate(value0: lawspec.data.Row): lawspec.data.Halves =
    Halves(lawspec.data.Record90e2e86ad982c9c5e71a6cd286ab605cf2b3d771c37021fb930810c33933eb3d(value0, value0))

  // (example.arithmetic::type::Row -> example.arithmetic::type::Pairs)
  def countPairs(value0: lawspec.data.Row): lawspec.data.Pairs =
    Pairs(value0)

  // (example.arithmetic::type::Row -> example.arithmetic::type::Rest)
  def dropFirst(value0: lawspec.data.Row): lawspec.data.Rest =
    Rest(value0)
}
