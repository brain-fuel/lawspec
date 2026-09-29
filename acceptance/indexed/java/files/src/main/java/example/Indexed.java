// User-owned LawSpec adapter.
package example;

import lawspec.data.Tree;
import lawspec.data.Vec;

public final class Indexed {
  public static Vec<Byte> replicate(java.math.BigInteger value0, byte value1) {
    Vec<Byte> result = new Vec.VNilCase<>();
    for (var i = java.math.BigInteger.ZERO; i.compareTo(value0) < 0; i = i.add(java.math.BigInteger.ONE)) {
      result = new Vec.VConsCase<>(value1, result);
    }
    return result;
  }

  public static Vec<Byte> append(Vec<Byte> value0, Vec<Byte> value1) {
    if (!(value0 instanceof Vec.VConsCase<Byte> cons)) return value1;
    return new Vec.VConsCase<>(cons.head, append(cons.tail, value1));
  }

  public static Vec<Boolean> zip(Vec<Byte> value0, Vec<Boolean> value1) {
    if (value0 instanceof Vec.VConsCase<Byte> a && value1 instanceof Vec.VConsCase<Boolean> b) {
      return new Vec.VConsCase<>(b.head, zip(a.tail, b.tail));
    }
    return new Vec.VNilCase<>();
  }

  public static Vec<Byte> flatten(Tree<Byte> value0) {
    if (!(value0 instanceof Tree.BinCase<Byte> node)) return new Vec.VNilCase<>();
    Vec<Byte> right = new Vec.VConsCase<>(node.value, flatten(node.right));
    return append(flatten(node.left), right);
  }
}
