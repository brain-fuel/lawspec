// User-owned LawSpec adapter.
package example;

import java.math.BigInteger;
import lawspec.data.Grid;
import lawspec.data.Halves;
import lawspec.data.Pairs;
import lawspec.data.Perfect;
import lawspec.data.Rest;
import lawspec.data.Row;

public final class Arithmetic {
  private static long length(Row row) {
    long count = 0;
    while (row instanceof Row.Cell cell) {
      count++;
      row = cell.value().tail();
    }
    return count;
  }

  public static Perfect mirror(Perfect value0) {
    return switch (value0) {
      case Perfect.Leaf leaf -> leaf;
      case Perfect.Node node -> new Perfect.Node(new lawspec.data.NodeDetails(mirror(node.value().right()), mirror(node.value().left())));
    };
  }

  public static BigInteger area(Grid value0) {
    return BigInteger.valueOf(length(value0.value().rows()) * length(value0.value().columns()));
  }

  public static Halves duplicate(Row value0) {
    return new Halves(new lawspec.data.HalvesDetails(value0, value0));
  }

  public static Pairs countPairs(Row value0) {
    return new Pairs(value0);
  }

  public static Rest dropFirst(Row value0) {
    return new Rest(value0);
  }
}
