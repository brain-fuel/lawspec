import java.math.BigInteger;
import java.util.HashMap;
import java.util.List;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Data;
import lawspec.runtime.LawSpecRuntime.Value;
import lawspec.runtime.LawSpecSchema;
import lawspec.runtime.LawSpecSchema.Constructor;
import lawspec.runtime.LawSpecSchema.Definition;
import lawspec.runtime.LawSpecSchema.Field;
import lawspec.runtime.LawSpecSchema.Named;
import lawspec.testing.LawSpecDataStrategies;
import org.jetbrains.jetCheck.Generator;
import org.jetbrains.jetCheck.PropertyChecker;
import org.jetbrains.jetCheck.PropertyFalsified;

public final class JavaCheckedStrategiesCheck {
  private static void require(boolean condition) {
    if (!condition) throw new AssertionError();
  }

  private static Value integer(int n) {
    return LawSpecRuntime.integer("Int8", Integer.toString(n));
  }

  public static void main(String[] args) {
    int bits = Integer.parseInt(args[0]);
    var symbols = new HashMap<String, Object>();
    var positive = new Named("Positive");
    var schema =
        new LawSpecSchema(
            List.of(
                new Definition(
                    "Positive",
                    0,
                    List.of(
                        new Constructor(
                            "Positive",
                            List.of(new Field("n", new Named("Int8"))),
                            List.of(
                                (s, ts, fs, b, context) ->
                                    ((BigInteger) fs.get(0).data()).signum() > 0))))));
    var list = new Named("List", positive);
    var witness =
        new Value(
            "List Positive",
            List.of(new Value("Positive", new Data("Positive", List.of(integer(1))))));
    var generator =
        LawSpecDataStrategies.checkedGenerator(
            schema,
            list,
            bits,
            64,
            symbols,
            List.of(witness),
            name -> Generator.integers(-5, 20).map(JavaCheckedStrategiesCheck::integer));
    PropertyChecker.customized()
        .withSeed(317)
        .withIterationCount(100)
        .silent()
        .forAll(
            generator,
            checked -> {
              schema.validate(list, checked.requireValue(), bits, symbols);
              return true;
            });
    try {
      PropertyChecker.customized()
          .withSeed(811)
          .withIterationCount(200)
          .silent()
          .forAll(
              generator,
              checked -> {
                var value = checked.requireValue();
                schema.validate(list, value, bits, symbols);
                return ((List<?>) value.data()).size() < 5;
              });
      throw new AssertionError("expected a shrunk list counterexample");
    } catch (PropertyFalsified failure) {
      var report = failure.getFailure();
      var minimal =
          (LawSpecDataStrategies.Checked) report.getMinimalCounterexample().getExampleValue();
      var first = (LawSpecDataStrategies.Checked) report.getFirstCounterExample().getExampleValue();
      int firstSize = ((List<?>) first.requireValue().data()).size();
      int minimalSize = ((List<?>) minimal.requireValue().data()).size();
      require(minimalSize >= 5 && minimalSize <= firstSize);
      schema.validate(list, minimal.requireValue(), bits, symbols);
      require(report.getTotalShrinkingExampleCount() > 0);
      require(report.getMinimalCounterexample().getExceptionCause() == null);
    }
    var seeded =
        LawSpecDataStrategies.checkedGenerator(
            schema,
            list,
            bits,
            64,
            symbols,
            List.of(witness),
            name -> Generator.constant(integer(0)));
    var lengths = new java.util.HashSet<Integer>();
    PropertyChecker.customized()
        .withSeed(123)
        .withIterationCount(50)
        .silent()
        .forAll(
            seeded,
            checked -> {
              var value = checked.requireValue();
              schema.validate(list, value, bits, symbols);
              lengths.add(((List<?>) value.data()).size());
              return true;
            });
    require(lengths.stream().anyMatch(length -> length > 1));
    var exhausted =
        LawSpecDataStrategies.checkedGenerator(
            schema, positive, bits, 8, symbols, List.of(), name -> Generator.constant(integer(0)));
    try {
      PropertyChecker.customized()
          .withIterationCount(1)
          .silent()
          .forAll(
              exhausted,
              checked -> {
                throw new AssertionError("exhaustion reached property");
              });
      throw new AssertionError("empty domain unexpectedly generated");
    } catch (RuntimeException failure) {
      Throwable cause = failure;
      while (cause.getCause() != null) cause = cause.getCause();
      require(cause instanceof org.jetbrains.jetCheck.CannotSatisfyCondition);
    }
    var draws = new int[] {0};
    var limited =
        LawSpecDataStrategies.checkedGenerator(
            schema,
            positive,
            bits,
            8,
            3,
            symbols,
            List.of(),
            name ->
                Generator.integers()
                    .map(
                        ignored -> {
                          draws[0]++;
                          return integer(0);
                        }));
    try {
      PropertyChecker.customized()
          .withIterationCount(1)
          .silent()
          .forAll(
              limited,
              checked -> {
                throw new AssertionError("exhaustion reached property");
              });
      throw new AssertionError("configured budget ignored");
    } catch (RuntimeException failure) {
      Throwable cause = failure;
      while (cause.getCause() != null) cause = cause.getCause();
      require(cause.getMessage().contains("exhausted 3 attempts"));
      require(draws[0] == 3);
    }
    var smallBudget =
        LawSpecDataStrategies.checkedGenerator(
            schema,
            positive,
            bits,
            8,
            3,
            symbols,
            List.of(),
            name -> Generator.integers(0, 127).map(JavaCheckedStrategiesCheck::integer));
    try {
      PropertyChecker.customized()
          .withSeed(811)
          .withIterationCount(1)
          .silent()
          .forAll(
              smallBudget,
              checked -> {
                schema.validate(positive, checked.requireValue(), bits, symbols);
                return false;
              });
      throw new AssertionError("expected a counterexample");
    } catch (PropertyFalsified failure) {
      var report = failure.getFailure();
      var minimal =
          (LawSpecDataStrategies.Checked) report.getMinimalCounterexample().getExampleValue();
      schema.validate(positive, minimal.requireValue(), bits, symbols);
      require(report.getMinimalCounterexample().getExceptionCause() == null);
      require(report.getTotalShrinkingExampleCount() > 0);
    }
    var broken =
        new LawSpecSchema(
            List.of(
                new Definition(
                    "Broken",
                    0,
                    List.of(
                        new Constructor(
                            "Broken",
                            List.of(new Field("n", new Named("Int8"))),
                            List.of(
                                (s, ts, fs, b, context) -> {
                                  throw new IllegalStateException("predicate exploded");
                                }))))));
    var errors =
        LawSpecDataStrategies.checkedGenerator(
            broken,
            new Named("Broken"),
            bits,
            8,
            symbols,
            List.of(),
            name -> Generator.constant(integer(1)));
    PropertyChecker.customized()
        .withIterationCount(1)
        .silent()
        .forAll(
            errors,
            checked -> {
              require(checked.error() != null);
              require(!checked.error().getMessage().contains("exhausted"));
              require(checked.error().getMessage().contains("predicate exploded"));
              return true;
            });
    var identity = new Named("Identity");
    var identitySchema =
        new LawSpecSchema(
            List.of(
                new Definition(
                    "Identity",
                    0,
                    List.of(
                        new Constructor(
                            "Identity",
                            List.of(new Field("s", new Named("Symbol"))),
                            List.of(
                                (s, ts, fs, b, context) ->
                                    LawSpecRuntime.equal(
                                        fs.get(0),
                                        LawSpecRuntime.symbol("fixture", "same", context))))))));
    var expected = LawSpecRuntime.symbol("fixture", "same", symbols);
    var identityGenerator =
        LawSpecDataStrategies.checkedGenerator(
            identitySchema,
            identity,
            bits,
            8,
            symbols,
            List.of(),
            name -> Generator.constant(expected));
    PropertyChecker.customized()
        .withIterationCount(1)
        .silent()
        .forAll(
            identityGenerator,
            checked -> {
              identitySchema.validate(identity, checked.requireValue(), bits, symbols);
              return true;
            });
    try {
      LawSpecDataStrategies.checkedGenerator(
          schema,
          positive,
          bits,
          8,
          symbols,
          List.of(new Value("Positive", new Data("Positive", List.of(integer(0))))),
          name -> Generator.constant(integer(1)));
      throw new AssertionError("invalid witness accepted");
    } catch (LawSpecSchema.RefinementViolation expectedFailure) {
      // Witnesses must satisfy the complete type before their descendants are reused.
    }
    System.out.println(
        "Java checked strategies preserve contracts, shrinking, errors and context: " + bits);
  }
}
