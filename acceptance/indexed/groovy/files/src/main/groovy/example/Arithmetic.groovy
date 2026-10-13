// User-owned LawSpec adapter.
package example

import java.math.BigInteger
import lawspec.data.Grid
import lawspec.data.Halves
import lawspec.data.Pairs
import lawspec.data.Perfect
import lawspec.data.Rest
import lawspec.data.Row

@groovy.transform.CompileStatic
final class Arithmetic {
  private static long length(Row row) {
    long count = 0
    for (Row rest = row; rest instanceof Row.Cell; rest = ((Row.Cell) rest).tail()) count++
    count
  }

  static Perfect mirror(Perfect value0) {
    if (value0 instanceof Perfect.Node) {
      return new Perfect.Node(mirror(value0.right()), mirror(value0.left()))
    }
    value0
  }

  static BigInteger area(Grid value0) {
    return BigInteger.valueOf(length(value0.rows()) * length(value0.columns()))
  }

  static Halves duplicate(Row value0) {
    return new Halves(value0, value0)
  }

  static Pairs countPairs(Row value0) {
    return new Pairs(value0)
  }

  static Rest dropFirst(Row value0) {
    return new Rest(value0)
  }
}
