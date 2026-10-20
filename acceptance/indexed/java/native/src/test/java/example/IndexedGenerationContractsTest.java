package example;

import static org.junit.jupiter.api.Assertions.*;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import lawspec.runtime.LawSpecRuntime.Data;
import lawspec.runtime.LawSpecRuntime.Value;
import lawspec.runtime.LawSpecSchema;
import lawspec.runtime.LawSpecSchema.*;
import lawspec.testing.LawSpecDataStrategies;
import org.jetbrains.jetCheck.Generator;
import org.jetbrains.jetCheck.PropertyChecker;
import org.jetbrains.jetCheck.PropertyFalsified;
import org.junit.jupiter.api.Test;

/** Constructor predicates remain authoritative during index-guided draws and shrinking. */
public final class IndexedGenerationContractsTest {
  private static LawSpecSchema schema(FieldPredicate predicate) {
    return new LawSpecSchema(List.of(new Definition("Bounded", 0, List.of(
        new Constructor("Bounded", List.of(new Field("value", new Named("Int8"))),
            List.of(predicate), List.of("c0"))))));
  }

  private static Generator<LawSpecDataStrategies.Checked> generator(
      LawSpecSchema schema, Map<String, Object> symbols) {
    return LawSpecDataStrategies.checkedIndexedGenerator(
        schema, new Named("Bounded"), 64, 64, 100, symbols, 0,
        Map.of("Bounded", List.of("c0")),
        name -> Generator.integers(-128, 127).map(n -> new Value(name, java.math.BigInteger.valueOf(n))),
        Map.of());
  }

  @Test
  void shrinksWithinTheConstructorRestrictionUsingTheCaseContext() {
    var symbols = new HashMap<String, Object>();
    symbols.put("minimum", 3);
    var schema = schema((s, args, fields, bits, context) ->
        ((Number) fields.getFirst().data()).intValue() >= (int) context.get("minimum"));
    var draws = generator(schema, symbols);
    PropertyChecker.customized().withSeed(811).withIterationCount(100).silent().forAll(
        draws, checked -> {
          var value = checked.requireValue();
          assertInstanceOf(Accepted.class, schema.check(new Named("Bounded"), value, 64, symbols));
          return true;
        });
    try {
      PropertyChecker.customized().withSeed(811).withIterationCount(100).silent()
          .forAll(draws, checked -> { checked.requireValue(); return false; });
      fail("expected a shrunk counterexample");
    } catch (PropertyFalsified failure) {
      var checked = (LawSpecDataStrategies.Checked)
          failure.getFailure().getMinimalCounterexample().getExampleValue();
      var fields = ((Data) checked.requireValue().data()).fields();
      assertEquals(3, ((Number) fields.getFirst().data()).intValue());
      assertTrue(failure.getFailure().getTotalShrinkingExampleCount() > 0);
    }
  }

  @Test
  void predicateEvaluationErrorsReachThePropertyInsteadOfBecomingRejections() {
    var schema = schema((s, args, fields, bits, context) -> {
      throw new IllegalStateException("predicate evaluation failed");
    });
    PropertyChecker.customized().withSeed(811).withIterationCount(10).silent().forAll(
        generator(schema, new HashMap<>()), checked -> {
          var error = assertThrows(IllegalArgumentException.class, checked::requireValue);
          assertTrue(error.getMessage().contains("predicate evaluation failed"));
          assertInstanceOf(IllegalStateException.class, error.getCause());
          return true;
        });
  }
}
