package example;

import static org.junit.jupiter.api.Assertions.*;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import lawspec.runtime.LawSpecDataSchema;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Data;
import lawspec.runtime.LawSpecRuntime.Presence;
import lawspec.runtime.LawSpecRuntime.Value;
import lawspec.runtime.LawSpecSchema;
import lawspec.runtime.LawSpecSchema.Named;
import lawspec.testing.LawSpecDataStrategies;
import org.jetbrains.jetCheck.Generator;
import org.jetbrains.jetCheck.PropertyChecker;
import org.jetbrains.jetCheck.PropertyFalsified;
import org.junit.jupiter.api.Test;

public final class DataStrategiesTest {
  private static int nodes(Value value) {
    if (value.data() instanceof Data data)
      return 1 + data.fields().stream().mapToInt(DataStrategiesTest::nodes).sum();
    if (value.type().startsWith("List "))
      return 1 + ((List<?>) value.data()).stream().mapToInt(item -> nodes((Value) item)).sum();
    if (value.data() instanceof Presence presence)
      return 1 + (presence.present() ? nodes(presence.value()) : 0);
    return 1;
  }

  private static boolean hasNonzero(Value value) {
    if (value.data() instanceof Data data)
      return data.fields().stream().anyMatch(DataStrategiesTest::hasNonzero);
    if (value.type().startsWith("List "))
      return ((List<?>) value.data()).stream().anyMatch(item -> hasNonzero((Value) item));
    return value.data() instanceof BigInteger integer && integer.signum() != 0;
  }

  @Test
  void refinedListsRetainNativeShrinkingAndEmptyDomains() {
    var schema = LawSpecDataSchema.create();
    var type = new Named("List", new Named("Int8"));
    var base =
        Generator.listsOf(Generator.integers(-128, 127))
            .map(
                xs ->
                    LawSpecRuntime.list(
                        "List Int8",
                        xs.stream()
                            .map(n -> LawSpecRuntime.integer("Int8", n.toString()))
                            .toList()));
    var generator =
        base.map(
            value ->
                LawSpecRuntime.refineElements(
                    value,
                    item -> item,
                    item -> LawSpecRuntime.bool(((BigInteger) item.data()).signum() > 0)));
    var failure =
        assertThrows(
            PropertyFalsified.class,
            () ->
                PropertyChecker.customized()
                    .withSeed(811)
                    .withIterationCount(200)
                    .withSizeHint(i -> 40)
                    .silent()
                    .forAll(
                        generator,
                        value -> {
                          schema.validate(type, value, 64);
                          assertTrue(
                              LawSpecRuntime.truth(
                                  LawSpecRuntime.allElements(
                                      value,
                                      item ->
                                          LawSpecRuntime.bool(
                                              ((BigInteger) item.data()).signum() > 0))));
                          return ((List<?>) value.data()).size() < 5;
                        }));
    var report = failure.getFailure();
    Value minimal = (Value) report.getMinimalCounterexample().getExampleValue();
    assertEquals(5, ((List<?>) minimal.data()).size());
    assertTrue(report.getTotalShrinkingExampleCount() > 0);
    assertEquals(
        List.of(),
        LawSpecRuntime.refineElements(minimal, item -> item, item -> LawSpecRuntime.bool(false))
            .data());
    assertEquals(
        minimal,
        LawSpecRuntime.refineElements(minimal, item -> item, item -> LawSpecRuntime.bool(true)));
  }

  @Test
  void nativeGenerationAndShrinkingStayValidAndBounded() {
    var schema = LawSpecDataSchema.create();
    var type = new Named("example.data_types::type::Tree", new Named("Int8"));
    var generator =
        LawSpecDataStrategies.generator(
            schema,
            type,
            64,
            64,
            name ->
                Generator.integers(-128, 127).map(n -> LawSpecRuntime.integer(name, n.toString())));
    Set<String> tags = new HashSet<>();
    PropertyChecker.customized()
        .withSeed(317)
        .withIterationCount(200)
        .withSizeHint(i -> i * 2 + 8)
        .forAll(
            generator,
            value -> {
              schema.validate(type, value, 64);
              assertTrue(nodes(value) <= 64);
              tags.add(((Data) value.data()).tag());
              return true;
            });
    assertEquals(2, tags.size());
    var failure =
        assertThrows(
            PropertyFalsified.class,
            () ->
                PropertyChecker.customized()
                    .withSeed(811)
                    .withIterationCount(200)
                    .silent()
                    .forAll(
                        generator,
                        value -> {
                          schema.validate(type, value, 64);
                          assertTrue(nodes(value) <= 64);
                          return !hasNonzero(value);
                        }));
    var report = failure.getFailure();
    Value first = (Value) report.getFirstCounterExample().getExampleValue();
    Value minimal = (Value) report.getMinimalCounterexample().getExampleValue();
    schema.validate(type, minimal, 64);
    assertTrue(hasNonzero(minimal));
    assertTrue(nodes(minimal) <= nodes(first));
    assertTrue(report.getTotalShrinkingExampleCount() > 0);
    assertNull(report.getMinimalCounterexample().getExceptionCause());
  }

  @Test
  void distributesBudgetAccordingToEachFieldsMinimum() {
    var declarations = new ArrayList<LawSpecSchema.Definition>();
    Named previous = new Named("Bool");
    for (int i = 0; i < 5; i++) {
      var name = "Chain" + i;
      declarations.add(
          new LawSpecSchema.Definition(
              name,
              0,
              List.of(
                  new LawSpecSchema.Constructor(
                      name, List.of(new LawSpecSchema.Field("inner", previous))))));
      previous = new Named(name);
    }
    var fields = new ArrayList<LawSpecSchema.Field>();
    fields.add(new LawSpecSchema.Field("heavy", previous));
    for (int i = 0; i < 9; i++) fields.add(new LawSpecSchema.Field("flag" + i, new Named("Bool")));
    declarations.add(
        new LawSpecSchema.Definition(
            "Wide", 0, List.of(new LawSpecSchema.Constructor("Wide", fields))));
    var schema = new LawSpecSchema(declarations);
    var type = new Named("Wide");
    var generator =
        LawSpecDataStrategies.generator(
            schema, type, 64, 16, name -> Generator.booleans().map(LawSpecRuntime::bool));
    PropertyChecker.customized()
        .withSeed(444)
        .withIterationCount(50)
        .forAll(
            generator,
            value -> {
              schema.validate(type, value, 64);
              assertEquals(16, nodes(value));
              return true;
            });
    assertThrows(
        IllegalArgumentException.class,
        () ->
            LawSpecDataStrategies.generator(
                schema, type, 64, 15, name -> Generator.booleans().map(LawSpecRuntime::bool)));
  }

  @Test
  void growsSingletonElementListsWithoutExhaustingJetCheckUniqueness() {
    var schema = new LawSpecSchema(List.of(new LawSpecSchema.Definition("Empty", 0, List.of())));
    var type = new Named("List", new Named("Maybe", new Named("Empty")));
    var generator =
        LawSpecDataStrategies.sizedGenerator(
            schema,
            type,
            64,
            64,
            name -> {
              throw new AssertionError("no scalar payload exists");
            });
    Set<Integer> sizes = new HashSet<>();
    PropertyChecker.customized()
        .withSeed(617)
        .withIterationCount(250)
        .withSizeHint(i -> i * 2 + 8)
        .forAll(
            generator,
            value -> {
              schema.validate(type, value, 64);
              sizes.add(((List<?>) value.data()).size());
              return true;
            });
    assertTrue(sizes.size() > 8);
  }
}
