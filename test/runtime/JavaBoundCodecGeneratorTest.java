package bound;

import static org.junit.jupiter.api.Assertions.*;

import java.math.BigInteger;
import java.util.HashMap;
import java.util.List;
import lawspec.runtime.LawSpecDataSchema;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Data;
import lawspec.runtime.LawSpecSchema.Named;
import lawspec.testing.LawSpecDataStrategies;
import lawspec.testing.LawSpecNativeGenerators;
import org.jetbrains.jetCheck.Generator;
import org.jetbrains.jetCheck.PropertyChecker;
import org.jetbrains.jetCheck.PropertyFalsified;
import org.junit.jupiter.api.Test;

public final class JavaBoundCodecGeneratorTest {
  private static int nativeMinimum() {
    try {
      PropertyChecker.customized().withSeed(811).withIterationCount(100).silent()
          .forAll(domain.CodecGenerators.parcels(domain.CodecGenerators.bytes()),
              value -> value.unpack() < 40);
      throw new AssertionError("expected a native counterexample");
    } catch (PropertyFalsified failure) {
      var minimal = (domain.CodecDomain.Parcel<?>)
          failure.getFailure().getMinimalCounterexample().getExampleValue();
      return ((Byte) minimal.unpack()).intValue();
    }
  }

  @Test
  void genericCodecRetainsChildShrinking() {
    var generator = LawSpecDataStrategies.checkedGenerator(
        LawSpecDataSchema.create(),
        new Named("bound.codecs::type::Parcel", new Named("Int8")),
        64, 64, 10, new HashMap<>(), List.of(),
        name -> Generator.integers(1, 100).map(
            value -> LawSpecRuntime.integer("Int8", value.toString())),
        LawSpecNativeGenerators.factories());
    try {
      PropertyChecker.customized().withSeed(811).withIterationCount(100).silent()
          .forAll(generator, value -> {
            var fields = ((Data) value.requireValue().data()).fields();
            return ((BigInteger) fields.getFirst().data()).intValueExact() < 40;
          });
      fail("expected a shrunk counterexample");
    } catch (PropertyFalsified failure) {
      var minimal = (LawSpecDataStrategies.Checked)
          failure.getFailure().getMinimalCounterexample().getExampleValue();
      var fields = ((Data) minimal.requireValue().data()).fields();
      var first = (LawSpecDataStrategies.Checked)
          failure.getFailure().getFirstCounterExample().getExampleValue();
      var initial = (BigInteger) ((Data) first.requireValue().data()).fields().getFirst().data();
      var shrunk = (BigInteger) fields.getFirst().data();
      assertTrue(shrunk.intValueExact() >= 40);
      assertTrue(shrunk.compareTo(initial) < 0, "native child did not shrink");
      assertEquals(nativeMinimum(), shrunk.intValueExact());
      System.out.println("Java codec child shrinking: " + initial + " -> " + shrunk);
      assertTrue(failure.getFailure().getTotalShrinkingExampleCount() > 0);
    }
  }
}
