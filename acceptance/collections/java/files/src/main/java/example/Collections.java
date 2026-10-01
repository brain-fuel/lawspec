// User-owned LawSpec adapter.
package example;

import java.math.BigInteger;
import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

public final class Collections {
  public static Set<Integer> dedupe(List<Integer> value0) {
    return new HashSet<>(value0);
  }

  public static Map<String, BigInteger> wordCounts(List<String> value0) {
    var counts = new HashMap<String, BigInteger>();
    for (var word : value0) counts.merge(word, BigInteger.ONE, BigInteger::add);
    return counts;
  }

  public static ArrayDeque<Byte> fifo(List<Byte> value0) {
    return new ArrayDeque<>(value0);
  }

  // A Stack is an ArrayDeque whose head, where push adds, is its top.
  public static ArrayDeque<Byte> lifo(List<Byte> value0) {
    var stack = new ArrayDeque<Byte>();
    for (var value : value0) stack.push(value);
    return stack;
  }

  public static ArrayDeque<Byte> rotate(ArrayDeque<Byte> value0) {
    var rotated = new ArrayDeque<>(value0);
    if (!rotated.isEmpty()) rotated.addLast(rotated.pollFirst());
    return rotated;
  }

  // Lists compare by value, so they can be Set elements directly.
  public static Set<List<Byte>> distinctRows(List<List<Byte>> value0) {
    return new LinkedHashSet<>(value0);
  }
}
