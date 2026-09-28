import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Objects;
import lawspec.data.Tree;
import lawspec.definitions.example.Total;
import lawspec.runtime.LawSpecRuntime;

public final class JavaDefinitionsCheck {
  static void equal(Object actual, Object expected) {
    if (!Objects.equals(actual, expected)) throw new AssertionError(actual + " != " + expected);
  }

  static void rejected(Runnable run) {
    try {
      run.run();
      throw new AssertionError("expected domain failure");
    } catch (IllegalArgumentException expected) {
      if (!expected.getMessage().contains("example.total::"))
        throw new AssertionError("missing definition context", expected);
    }
  }

  public static void main(String[] args) {
    int bits = Integer.parseInt(args[0]);
    var symbols = new HashMap<String, Object>();
    equal(Total.size(symbols, List.of((byte) 1, (byte) 2, (byte) 3)), BigInteger.valueOf(3));
    equal(Total.forward(symbols, List.of()), BigInteger.ZERO);
    equal(Total.sumList(symbols, List.of((byte) 127, (byte) 127)), BigInteger.valueOf(254));
    equal(Total.increment(symbols, (byte) 127), BigInteger.valueOf(128));
    equal(Total.divisible(symbols, BigInteger.ONE, BigInteger.ZERO), false);
    equal(Total.divisible(symbols, BigInteger.valueOf(-6), BigInteger.valueOf(3)), true);
    equal(Total.maybeDefault(symbols, new LawSpecRuntime.Nothing<>()), (byte) 0);
    equal(Total.maybeDefault(symbols, new LawSpecRuntime.Just<>((byte) 127)), (byte) 127);
    equal(Total.raw(symbols, List.of('\ud800', '\0', '\uffff')), List.of('\ud800', '\0', '\uffff'));
    var original = new ArrayList<>(List.of('\ud800'));
    var copied = Total.raw(symbols, original);
    original.set(0, 'a');
    equal(copied, List.of('\ud800'));
    equal(
        Total.sumTree(
            symbols,
            new Tree.BranchCase(new Tree.LeafCase((byte) 127), new Tree.LeafCase((byte) 127))),
        BigInteger.valueOf(254));
    equal(lawspec.definitions.Other.size(symbols, true), true);
    equal(lawspec.definitions.Other.size(symbols, false), false);
    for (var state :
        List.of(
            LawSpecRuntime.present("Optional Nullable Int8", null),
            LawSpecRuntime.present(
                "Optional Nullable Int8", LawSpecRuntime.present("Nullable Int8", null)),
            LawSpecRuntime.present(
                "Optional Nullable Int8",
                LawSpecRuntime.present("Nullable Int8", LawSpecRuntime.integer("Int8", "0"))))) {
      if (!LawSpecRuntime.equal(Total.absent(symbols, state), state))
        throw new AssertionError("absence");
    }
    if (!LawSpecRuntime.equal(
        Total.symbol(symbols, LawSpecRuntime.absent("Unit")),
        Total.symbol(symbols, LawSpecRuntime.absent("Unit"))))
      throw new AssertionError("symbol identity");
    equal(Total.exact(symbols, new BigDecimal("0.1")).compareTo(new BigDecimal("0.3")), 0);
    if (!(Total.either(symbols, new LawSpecRuntime.Left<>((byte) 127))
            instanceof LawSpecRuntime.Left<Byte, Boolean> left)
        || left.value() != 127) throw new AssertionError("left");
    if (!(Total.either(symbols, new LawSpecRuntime.Right<>(true))
            instanceof LawSpecRuntime.Right<Byte, Boolean> right)
        || !right.value()) throw new AssertionError("right");
    var maximum = BigInteger.ONE.shiftLeft(bits - 1).subtract(BigInteger.ONE);
    equal(
        Total.machine(symbols, LawSpecRuntime.integer("IntSize", maximum.toString())).data(),
        maximum);
    rejected(
        () ->
            Total.machine(
                symbols,
                LawSpecRuntime.integer("IntSize", maximum.add(BigInteger.ONE).toString())));
    rejected(() -> Total.maybeDefault(symbols, null));
    rejected(() -> Total.raw(symbols, null));
    System.out.println("Java standalone definition calls passed: " + bits);
  }
}
