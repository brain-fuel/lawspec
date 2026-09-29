import java.math.BigInteger;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Data;
import lawspec.runtime.LawSpecRuntime.Value;
import lawspec.runtime.LawSpecSchema;
import lawspec.runtime.LawSpecSchema.Named;
import lawspec.testing.LawSpecDataStrategies;
import lawspec.testing.LawSpecDataStrategies.NativeFactory;
import org.jetbrains.jetCheck.Generator;
import org.jetbrains.jetCheck.PropertyChecker;
import org.jetbrains.jetCheck.PropertyFalsified;

public final class JavaNativeGeneratorsCheck {
  private static int profileBits;

  record Box(byte payload) {}

  static Value integer(int n) {
    return LawSpecRuntime.integer("Int8", Integer.toString(n));
  }

  static void require(boolean condition) {
    if (!condition) throw new AssertionError();
  }

  static LawSpecSchema schema() {
    return new LawSpecSchema(
        List.of(
            new LawSpecSchema.Definition(
                "Box",
                1,
                List.of(
                    new LawSpecSchema.Constructor(
                        "Box::Box",
                        List.of(
                            new LawSpecSchema.Field("value", new LawSpecSchema.Parameter(0))))))));
  }

  static Generator<LawSpecDataStrategies.Checked> strategy(
      Named type, Map<String, NativeFactory> factories, List<Value> witnesses) {
    return LawSpecDataStrategies.checkedGenerator(
        schema(),
        type,
        profileBits,
        32,
        10,
        new HashMap<>(),
        witnesses,
        name -> Generator.integers(-128, 127).map(JavaNativeGeneratorsCheck::integer),
        factories);
  }

  static void emptyParameters() {
    var schema =
        new LawSpecSchema(
            List.of(
                new LawSpecSchema.Definition("Empty", 0, List.of()),
                new LawSpecSchema.Definition(
                    "Phantom",
                    1,
                    List.of(
                        new LawSpecSchema.Constructor(
                            "Phantom::Phantom",
                            List.of(new LawSpecSchema.Field("value", new Named("Int8"))))))));
    var type = new Named("Phantom", new Named("Empty"));
    for (boolean demand : List.of(false, true)) {
      NativeFactory factory =
          (registry, reference, bits, symbols, children) -> {
            require(children.size() == 1);
            var values =
                demand ? children.getFirst().map(ignored -> 40) : Generator.integers(40, 100);
            return values.map(
                value ->
                    new Value(
                        LawSpecSchema.key(type),
                        new Data("Phantom::Phantom", List.of(integer(value)))));
          };
      var generated =
          LawSpecDataStrategies.checkedGenerator(
              schema,
              type,
              profileBits,
              32,
              10,
              new HashMap<>(),
              List.of(),
              name -> Generator.integers(-128, 127).map(JavaNativeGeneratorsCheck::integer),
              Map.of("Phantom", factory));
      try {
        PropertyChecker.customized()
            .withSeed(811)
            .withIterationCount(100)
            .silent()
            .forAll(
                generated,
                checked ->
                    ((BigInteger) ((Data) checked.requireValue().data()).fields().getFirst().data())
                            .intValueExact()
                        < 40);
        throw new AssertionError("expected rejection or counterexample");
      } catch (PropertyFalsified failure) {
        require(!demand);
        var value =
            (LawSpecDataStrategies.Checked)
                failure.getFailure().getMinimalCounterexample().getExampleValue();
        int minimal =
            ((BigInteger) ((Data) value.requireValue().data()).fields().getFirst().data())
                .intValueExact();
        require(minimal >= 40 && minimal <= 100);
        require(failure.getFailure().getTotalShrinkingExampleCount() > 0);
      } catch (RuntimeException failure) {
        if (!demand)
          throw new AssertionError("unused empty parameter blocked native factory", failure);
        Throwable cause = failure;
        while (cause.getCause() != null) cause = cause.getCause();
        require(cause.toString().contains("CannotSatisfyCondition"));
      }
    }
    var emptyRoot =
        LawSpecDataStrategies.checkedGenerator(
            schema,
            new Named("Empty"),
            profileBits,
            32,
            10,
            new HashMap<>(),
            List.of(),
            name -> Generator.constant(integer(0)),
            Map.of());
    try {
      PropertyChecker.customized()
          .withIterationCount(1)
          .silent()
          .forAll(emptyRoot, checked -> true);
      throw new AssertionError("empty root supplied a value");
    } catch (RuntimeException failure) {
      Throwable cause = failure;
      while (cause.getCause() != null) cause = cause.getCause();
      require(cause.toString().contains("no inhabitant of Empty"));
    }
  }

  public static void main(String[] args) {
    profileBits = Integer.parseInt(args[0]);
    emptyParameters();
    NativeFactory bytes =
        (schema, type, bits, symbols, children) ->
            LawSpecDataStrategies.nativeValues(
                schema.scalar("Int8", bits, Byte.class),
                Generator.integers(40, 100).map(Integer::byteValue));
    NativeFactory boxes =
        (schema, type, bits, symbols, children) -> {
          var child = schema.scalar("Int8", bits, Byte.class);
          var codec =
              schema.<Box>codec(
                  type,
                  bits,
                  symbols,
                  value ->
                      new Value(
                          LawSpecSchema.key(type),
                          new Data("Box::Box", List.of(child.encode(value.payload())))),
                  value -> new Box(child.decode(((Data) value.data()).fields().getFirst())));
          return LawSpecDataStrategies.nativeValues(
              codec,
              LawSpecDataStrategies.nativeArguments(child, children.getFirst()).map(Box::new));
        };
    var boxType = new Named("Box", new Named("Int8"));
    var generated = strategy(boxType, Map.of("Box", boxes, "Int8", bytes), List.of());
    try {
      PropertyChecker.customized()
          .withSeed(811)
          .withIterationCount(100)
          .silent()
          .forAll(
              generated,
              checked -> {
                var value = checked.requireValue();
                var field = ((Data) value.data()).fields().getFirst();
                return ((BigInteger) field.data()).intValueExact() < 40;
              });
      throw new AssertionError("expected counterexample");
    } catch (PropertyFalsified failure) {
      var checked =
          (LawSpecDataStrategies.Checked)
              failure.getFailure().getMinimalCounterexample().getExampleValue();
      var field = ((Data) checked.requireValue().data()).fields().getFirst();
      var first =
          (LawSpecDataStrategies.Checked)
              failure.getFailure().getFirstCounterExample().getExampleValue();
      int initial =
          ((BigInteger) ((Data) first.requireValue().data()).fields().getFirst().data())
              .intValueExact();
      int minimal = ((BigInteger) field.data()).intValueExact();
      System.out.println("native shrink " + initial + " -> " + minimal);
      require(minimal >= 40 && minimal < initial);
      require(failure.getFailure().getTotalShrinkingExampleCount() > 0);
    }
    NativeFactory invalid =
        (schema, type, bits, symbols, children) -> Generator.constant(integer(128));
    PropertyChecker.customized()
        .withSeed(10)
        .withIterationCount(1)
        .silent()
        .forAll(
            strategy(new Named("Int8"), Map.of("Int8", invalid), List.of()),
            checked ->
                checked.error() != null
                    && checked.error().getMessage().contains("native generator Int8"));

    NativeFactory invalidShrink =
        (schema, type, bits, symbols, children) ->
            Generator.integers(0, 100).map(n -> integer(n == 0 ? 128 : n));
    try {
      PropertyChecker.customized()
          .withSeed(811)
          .withIterationCount(100)
          .silent()
          .forAll(
              strategy(new Named("Int8"), Map.of("Int8", invalidShrink), List.of()),
              checked -> false);
      throw new AssertionError("expected shrink counterexample");
    } catch (PropertyFalsified failure) {
      var first =
          (LawSpecDataStrategies.Checked)
              failure.getFailure().getFirstCounterExample().getExampleValue();
      var last =
          (LawSpecDataStrategies.Checked)
              failure.getFailure().getMinimalCounterexample().getExampleValue();
      require(first.error() == null);
      require(last.error() != null);
      require(last.error().getMessage().contains("native generator Int8"));
    }
    var composed =
        LawSpecDataStrategies.capture(
            strategy(new Named("Int8"), Map.of("Int8", invalid), List.of())
                .map(LawSpecDataStrategies.Checked::requireValue)
                .map(List::of));
    try {
      PropertyChecker.customized()
          .withSeed(10)
          .withIterationCount(1)
          .silent()
          .forAll(
              composed,
              captured -> {
                captured.requireValue();
                return true;
              });
      throw new AssertionError("native failure did not reach property callback");
    } catch (PropertyFalsified failure) {
      var captured =
          (LawSpecDataStrategies.Captured<?>)
              failure.getFailure().getMinimalCounterexample().getExampleValue();
      require(captured.error().getMessage().contains("native generator Int8"));
    }
    NativeFactory exhausted =
        (schema, type, bits, symbols, children) ->
            Generator.from(
                environment -> {
                  throw new IllegalStateException("custom exhausted");
                });
    try {
      PropertyChecker.customized()
          .withSeed(8)
          .withIterationCount(1)
          .silent()
          .forAll(
              strategy(new Named("Int8"), Map.of("Int8", exhausted), List.of(integer(42))),
              checked -> true);
      throw new AssertionError("custom generator used witness fallback");
    } catch (RuntimeException expected) {
      Throwable cause = expected;
      while (cause.getCause() != null) cause = cause.getCause();
      require(cause.getMessage().contains("custom exhausted"));
    }
    System.out.println(
        "Java native generators: composition, shrinking, failures and exhaustion pass");
  }
}
