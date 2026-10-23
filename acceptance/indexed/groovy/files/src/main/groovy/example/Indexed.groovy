// User-owned LawSpec adapter.
package example

import lawspec.data.Tree
import lawspec.data.Vec

@groovy.transform.CompileStatic
final class Indexed {
  static Vec<Byte> replicate(java.math.BigInteger value0, byte value1) {
    Vec<Byte> result = new Vec.VNil<>()
    for (var i = java.math.BigInteger.ZERO; i.compareTo(value0) < 0; i = i.add(java.math.BigInteger.ONE)) {
      result = new Vec.VCons<>(new lawspec.data.VConsDetails<>(value1, result))
    }
    return result
  }

  static Vec<Byte> append(Vec<Byte> value0, Vec<Byte> value1) {
    if (value0 instanceof Vec.VCons) {
      var cons = (Vec.VCons<Byte>) value0
      return new Vec.VCons<Byte>(new lawspec.data.VConsDetails<Byte>(cons.value().head(), append(cons.value().tail(), value1)))
    }
    value1
  }

  static Vec<Boolean> zip(Vec<Byte> value0, Vec<Boolean> value1) {
    if (value0 instanceof Vec.VCons && value1 instanceof Vec.VCons) {
      var bytes = (Vec.VCons<Byte>) value0
      var flags = (Vec.VCons<Boolean>) value1
      return new Vec.VCons<Boolean>(new lawspec.data.VConsDetails<Boolean>(flags.value().head(), zip(bytes.value().tail(), flags.value().tail())))
    }
    new Vec.VNil<>()
  }

  static Vec<Byte> flatten(Tree<Byte> value0) {
    if (value0 instanceof Tree.Bin) {
      var bin = (Tree.Bin<Byte>) value0
      return append(flatten(bin.value().left()), new Vec.VCons<Byte>(new lawspec.data.VConsDetails<Byte>(bin.value().value(), flatten(bin.value().right()))))
    }
    new Vec.VNil<>()
  }
}
