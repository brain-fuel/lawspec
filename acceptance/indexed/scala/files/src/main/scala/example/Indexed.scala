// User-owned LawSpec adapter.
package example

import lawspec.data.{Tree, Vec}

object Indexed {
  // (BigInt -> (Int8 -> example.indexed::type::Vec (Int8)))
  def replicate(value0: scala.math.BigInt, value1: scala.Byte): lawspec.data.Vec[scala.Byte] = {
    var result: Vec[scala.Byte] = Vec.VNil()
    var i = BigInt(0)
    while (i < value0) {
      result = Vec.VCons(lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(value1, result))
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
      case Vec.VCons(lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(head, tail)) => Vec.VCons(lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(head, append(tail, value1)))
      case Vec.VNil() => value1
    }

  // (example.indexed::type::Vec (Int8) -> (example.indexed::type::Vec (Bool) ->
  // example.indexed::type::Vec (Bool)))
  def zip(
    value0: lawspec.data.Vec[scala.Byte],
    value1: lawspec.data.Vec[scala.Boolean],
  ): lawspec.data.Vec[scala.Boolean] =
    (value0, value1) match {
      case (Vec.VCons(lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(_, tail0)), Vec.VCons(lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(head1, tail1))) =>
        Vec.VCons(lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(head1, zip(tail0, tail1)))
      case _ => Vec.VNil()
    }

  // (example.indexed::type::Tree (Int8) -> example.indexed::type::Vec (Int8))
  def flatten(value0: lawspec.data.Tree[scala.Byte]): lawspec.data.Vec[scala.Byte] =
    value0 match {
      case Tree.Tip() => Vec.VNil()
      case Tree.Bin(lawspec.data.Recorde00f7d8e028cf6be6e08b4ed1f9853199bee01cf39e5a2faa3e38b8ad29bf271(left, right, value)) =>
        val rest: Vec[scala.Byte] = Vec.VCons(lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(value, flatten(right)))
        append(flatten(left), rest)
    }
}
