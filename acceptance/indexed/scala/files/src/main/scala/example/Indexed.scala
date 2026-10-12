// User-owned LawSpec adapter.
package example

import lawspec.data.{Tree, Vec}

object Indexed {
  // (BigInt -> (Int8 -> example.indexed::type::Vec (Int8)))
  def replicate(value0: scala.math.BigInt, value1: scala.Byte): lawspec.data.Vec[scala.Byte] = {
    var result: Vec[scala.Byte] = Vec.VNil()
    var i = BigInt(0)
    while (i < value0) {
      result = Vec.VCons(value1, result)
      i += 1
    }
    result
  }

  // (example.indexed::type::Vec (Int8) -> (example.indexed::type::Vec (Int8) ->
  // example.indexed::type::Vec (Int8)))
  def append(
    value0: lawspec.data.Vec[scala.Byte],
    value1: lawspec.data.Vec[scala.Byte],
  ): lawspec.data.Vec[scala.Byte] =
    value0 match {
      case Vec.VCons(head, tail) => Vec.VCons(head, append(tail, value1))
      case Vec.VNil() => value1
    }

  // (example.indexed::type::Vec (Int8) -> (example.indexed::type::Vec (Bool) ->
  // example.indexed::type::Vec (Bool)))
  def zip(
    value0: lawspec.data.Vec[scala.Byte],
    value1: lawspec.data.Vec[scala.Boolean],
  ): lawspec.data.Vec[scala.Boolean] =
    (value0, value1) match {
      case (Vec.VCons(_, tail0), Vec.VCons(head1, tail1)) =>
        Vec.VCons(head1, zip(tail0, tail1))
      case _ => Vec.VNil()
    }

  // (example.indexed::type::Tree (Int8) -> example.indexed::type::Vec (Int8))
  def flatten(value0: lawspec.data.Tree[scala.Byte]): lawspec.data.Vec[scala.Byte] =
    value0 match {
      case Tree.Tip() => Vec.VNil()
      case Tree.Bin(left, value, right) =>
        val rest: Vec[scala.Byte] = Vec.VCons(value, flatten(right))
        append(flatten(left), rest)
    }
}
