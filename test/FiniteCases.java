import java.math.BigInteger;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import lawspec.runtime.LawSpecRuntime;

/**
 * Independent examples of ordered coverage, lazy ranges and per-invocation materialization.
 * ref:DEC-planned-generation
 */
public final class FiniteCases
{
  private static void require(boolean condition)
  {
    if (!condition)
    {
      throw new AssertionError("finite-cover conformance failed");
    }
  }

  private static LawSpecRuntime.FiniteValue integer(int value)
  {
    return symbols -> LawSpecRuntime.integer("Int8", Integer.toString(value));
  }

  public static void main(String[] arguments)
  {
    var suffix = LawSpecRuntime.finiteBranch(
        LawSpecRuntime.finiteValues(integer(2), integer(3)), LawSpecRuntime.finiteEnd(1));
    var cover = LawSpecRuntime.finiteChoices(
        LawSpecRuntime.finiteBranch(LawSpecRuntime.finiteRange("Int8", "0", "1"),
            LawSpecRuntime.finiteChoices(suffix)),
        LawSpecRuntime.finiteBranch(LawSpecRuntime.finiteValues(integer(1)),
            LawSpecRuntime.finiteChoices(LawSpecRuntime.finiteBranch(
                LawSpecRuntime.finiteValues(integer(9)), LawSpecRuntime.finiteEnd(2)))));
    var expected = List.of(List.of(0, 2), List.of(0, 3), List.of(1, 2), List.of(1, 3),
        List.of(1, 9), List.of(1, 9));
    int seen = 0;
    for (var row : LawSpecRuntime.finiteCases(cover))
    {
      require(row.index() == seen + 1);
      var values = row.values(new HashMap<>());
      var actual = values.stream()
          .map(value -> ((BigInteger) value.data()).intValueExact()).toList();
      require(actual.equals(expected.get(seen++)));
    }
    require(seen == expected.size());

    var previousSelection = System.getProperty("lawspec.case");
    try
    {
      System.setProperty("lawspec.case", "4");
      var selected = LawSpecRuntime.selectedFiniteCases(cover, "6").iterator();
      var selectedRow = selected.next();
      require(selectedRow.index() == 4);
      require(selectedRow.values(new HashMap<>()).getLast().data().equals(BigInteger.valueOf(3)));
      require(!selected.hasNext());
      for (var invalid : List.of("0", "7", "invalid"))
      {
        System.setProperty("lawspec.case", invalid);
        try
        {
          LawSpecRuntime.selectedFiniteCases(cover, "6").iterator();
          throw new AssertionError("invalid case selection passed");
        }
        catch (IllegalArgumentException expectedFailure)
        {
          require(expectedFailure.getMessage().contains("lawspec.case"));
        }
      }
    }
    finally
    {
      if (previousSelection == null)
      {
        System.clearProperty("lawspec.case");
      }
      else
      {
        System.setProperty("lawspec.case", previousSelection);
      }
    }

    var wide = LawSpecRuntime.finiteChoices(LawSpecRuntime.finiteBranch(
        LawSpecRuntime.finiteRange("UInt64", "18446744073709551614", "18446744073709551615"),
        LawSpecRuntime.finiteEnd(1)));
    var numbers = new ArrayList<String>();
    for (var row : LawSpecRuntime.finiteCases(wide))
    {
      numbers.add(row.values(new HashMap<>()).getFirst().data().toString());
    }
    require(numbers.equals(List.of("18446744073709551614", "18446744073709551615")));

    var calls = new AtomicInteger();
    var fresh = LawSpecRuntime.finiteChoices(LawSpecRuntime.finiteBranch(
        LawSpecRuntime.finiteValues(symbols -> {
          calls.incrementAndGet();
          return LawSpecRuntime.handle("Handle", new Object());
        }), LawSpecRuntime.finiteEnd(1)));
    var first = LawSpecRuntime.finiteCases(fresh).iterator().next();
    require(calls.get() == 0);
    var left = first.values(new HashMap<>()).getFirst();
    var right = first.values(new HashMap<>()).getFirst();
    require(calls.get() == 2);
    require(LawSpecRuntime.handleTarget(left) != LawSpecRuntime.handleTarget(right));

    var enormous = LawSpecRuntime.finiteChoices(LawSpecRuntime.finiteBranch(
        LawSpecRuntime.finiteRange("Integer", "0", "1000000000000000000000"),
        LawSpecRuntime.finiteEnd(1)));
    var iterator = LawSpecRuntime.finiteCases(enormous).iterator();
    for (int index = 0; index < 3; index++)
    {
      var value = iterator.next().values(new HashMap<>()).getFirst();
      require(value.data().equals(BigInteger.valueOf(index)));
    }
    require(!LawSpecRuntime.finiteCases(LawSpecRuntime.finiteChoices()).iterator().hasNext());
    require(!LawSpecRuntime.finiteCases(LawSpecRuntime.finiteEnd(0)).iterator().hasNext());
    System.out.println("JVM finite-cover conformance passed");
  }
}
