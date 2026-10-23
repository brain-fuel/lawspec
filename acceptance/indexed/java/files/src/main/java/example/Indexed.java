// User-owned LawSpec adapter.
package example;

import lawspec.data.Tree;
import lawspec.data.Vec;

public final class Indexed {
  public static Vec<Byte> replicate(java.math.BigInteger value0, byte value1) {
    Vec<Byte> result = new Vec.VNil<>();
    for (var i = java.math.BigInteger.ZERO; i.compareTo(value0) < 0; i = i.add(java.math.BigInteger.ONE)) {
      result = new Vec.VCons<>(new lawspec.data.VConsDetails<>(value1, result));
    }
    return result;
  }

  public static Vec<Byte> append(Vec<Byte> value0, Vec<Byte> value1) {
    return switch (value0) {
      case Vec.VNil<Byte> nil -> value1;
      case Vec.VCons<Byte>(lawspec.data.VConsDetails<Byte>(var head, var tail)) -> new Vec.VCons<>(new lawspec.data.VConsDetails<>(head, append(tail, value1)));
    };
  }

  public static Vec<Boolean> zip(Vec<Byte> value0, Vec<Boolean> value1) {
    if (value0 instanceof Vec.VCons<Byte>(lawspec.data.VConsDetails<Byte>(var a, var as)) && value1 instanceof Vec.VCons<Boolean>(lawspec.data.VConsDetails<Boolean>(var b, var bs))) {
      return new Vec.VCons<>(new lawspec.data.VConsDetails<>(b, zip(as, bs)));
    }
    return new Vec.VNil<>();
  }

  public static Vec<Byte> flatten(Tree<Byte> value0) {
    return switch (value0) {
      case Tree.Tip<Byte> tip -> new Vec.VNil<>();
      case Tree.Bin<Byte>(lawspec.data.BinDetails<Byte>(var left, var right, var value)) -> append(flatten(left), new Vec.VCons<>(new lawspec.data.VConsDetails<>(value, flatten(right))));
    };
  }
}
