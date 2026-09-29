package bound;

import static org.junit.jupiter.api.Assertions.*;

import domain.PaymentGenerators;
import java.math.BigDecimal;
import java.util.HashMap;
import java.util.List;
import lawspec.runtime.LawSpecDataSchema;
import lawspec.runtime.LawSpecRuntime.Data;
import lawspec.runtime.LawSpecSchema.Named;
import lawspec.testing.LawSpecDataStrategies;
import lawspec.testing.LawSpecNativeGenerators;
import org.jetbrains.jetCheck.PropertyChecker;
import org.jetbrains.jetCheck.PropertyFalsified;
import org.junit.jupiter.api.Test;

public final class NativeGeneratorContractsTest {
  @Test
  void nativeMoneyShrinks() {
    var generator =
        LawSpecDataStrategies.checkedGenerator(
            LawSpecDataSchema.create(),
            new Named("example.payments::type::Money"),
            64,
            64,
            10,
            new HashMap<>(),
            List.of(),
            name -> {
              throw new AssertionError("Money factory supplies its native values");
            },
            LawSpecNativeGenerators.factories());
    try {
      PropertyChecker.customized()
          .withSeed(811)
          .withIterationCount(100)
          .silent()
          .forAll(
              generator,
              value -> {
                value.requireValue();
                return false;
              });
      fail("expected a shrunk counterexample");
    } catch (PropertyFalsified failure) {
      var minimal =
          (LawSpecDataStrategies.Checked)
              failure.getFailure().getMinimalCounterexample().getExampleValue();
      var fields = ((Data) minimal.requireValue().data()).fields();
      assertEquals(0, ((BigDecimal) fields.getFirst().data()).compareTo(new BigDecimal("1.00")));
      assertEquals("example.payments::type::Currency::EUR", ((Data) fields.get(1).data()).tag());
      assertTrue(failure.getFailure().getTotalShrinkingExampleCount() > 0);
    }
  }

  @Test
  void refinedScalarUsesConfiguredFactory() {
    PaymentGenerators.byteSamples.set(0);
    new ShapesLawSpecTest().law5Property();
    assertTrue(PaymentGenerators.byteSamples.get() > 0);
  }

  @Test
  void finiteSealDoesNotSample() {
    new ShapesLawSpecTest().law4Boundary0();
  }
}
