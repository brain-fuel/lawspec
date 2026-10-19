// User-owned LawSpec adapter.
package example;

import lawspec.data.Tree;
import lawspec.data.Vec;

public final class Indexed {
  public static Vec<Byte> replicate(java.math.BigInteger value0, byte value1) {
    Vec<Byte> result = new Vec.VNil<>();
    for (var i = java.math.BigInteger.ZERO; i.compareTo(value0) < 0; i = i.add(java.math.BigInteger.ONE)) {
      result = new Vec.VCons<>(new lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec<>(value1, result));
    }
    return result;
  }

  public static Vec<Byte> append(Vec<Byte> value0, Vec<Byte> value1) {
    return switch (value0) {
      case Vec.VNil<Byte> nil -> value1;
      case Vec.VCons<Byte>(lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec<Byte>(var head, var tail)) -> new Vec.VCons<>(new lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec<>(head, append(tail, value1)));
    };
  }

  public static Vec<Boolean> zip(Vec<Byte> value0, Vec<Boolean> value1) {
    if (value0 instanceof Vec.VCons<Byte>(lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec<Byte>(var a, var as)) && value1 instanceof Vec.VCons<Boolean>(lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec<Boolean>(var b, var bs))) {
      return new Vec.VCons<>(new lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec<>(b, zip(as, bs)));
    }
    return new Vec.VNil<>();
  }

  public static Vec<Byte> flatten(Tree<Byte> value0) {
    return switch (value0) {
      case Tree.Tip<Byte> tip -> new Vec.VNil<>();
      case Tree.Bin<Byte>(lawspec.data.Recorde00f7d8e028cf6be6e08b4ed1f9853199bee01cf39e5a2faa3e38b8ad29bf271<Byte>(var left, var right, var value)) -> append(flatten(left), new Vec.VCons<>(new lawspec.data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec<>(value, flatten(right))));
    };
  }
}
