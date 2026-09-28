import java.util.HashMap;
import java.util.List;
import java.util.Map;
import lawspec.data.Bucket;
import lawspec.data.Choice;
import lawspec.data.Gap;
import lawspec.data.Guarded;
import lawspec.data.Identity;
import lawspec.data.Machine;
import lawspec.data.Positives;
import lawspec.data.Raw;
import lawspec.definitions.fixture.Fields;
import lawspec.runtime.LawSpecDataCodecs;
import lawspec.runtime.LawSpecDataSchema;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Presence;
import lawspec.runtime.LawSpecRuntime.Value;

public final class JavaNativeConstructorCheck {
  private static void require(boolean condition) {
    if (!condition) throw new AssertionError();
  }

  private static void rejected(Runnable action) {
    try {
      action.run();
    } catch (IllegalArgumentException expected) {
      require(expected.getMessage().contains("field refinement"));
      require(!expected.getMessage().contains("division by zero"));
      return;
    }
    throw new AssertionError("invalid native constructor accepted");
  }

  public static void main(String[] args) {
    int bits = Integer.parseInt(args[0]);
    Map<String, Object> symbols = new HashMap<>();
    require(
        LawSpecRuntime.equal(
            Fields.inverseGap(symbols, new Gap.GapCase((byte) -128, (byte) 127)),
            LawSpecRuntime.rational("1", "255")));
    rejected(() -> Fields.inverseGap(symbols, new Gap.GapCase((byte) 0, (byte) 0)));
    rejected(() -> Fields.inverseGap(symbols, new Gap.GapCase((byte) 127, (byte) -128)));
    Fields.echoBucket(symbols, new Bucket.BucketCase<>(List.of((byte) 1)));
    rejected(() -> Fields.echoBucket(symbols, new Bucket.BucketCase<>(List.of())));
    Fields.echoPositives(symbols, new Positives.PositivesCase(List.of((byte) 1)));
    rejected(() -> Fields.echoPositives(symbols, new Positives.PositivesCase(List.of((byte) 0))));
    Fields.echoChoice(symbols, new Choice.AcceptedCase((byte) 1));
    Fields.echoChoice(symbols, new Choice.RejectedCase("no"));
    rejected(() -> Fields.echoChoice(symbols, new Choice.AcceptedCase((byte) 0)));
    Fields.echoGuarded(symbols, new Guarded.GuardedCase((byte) 2));
    rejected(() -> Fields.echoGuarded(symbols, new Guarded.GuardedCase((byte) 0)));
    rejected(() -> Fields.echoGuarded(symbols, new Guarded.GuardedCase((byte) -1)));
    Fields.echoMachine(symbols, new Machine.MachineCase(LawSpecRuntime.integer("IntSize", "1")));
    rejected(
        () ->
            Fields.echoMachine(
                symbols, new Machine.MachineCase(LawSpecRuntime.integer("IntSize", "0"))));
    if (bits == 64) {
      Fields.echoMachine(
          symbols, new Machine.MachineCase(LawSpecRuntime.integer("IntSize", "1099511627776")));
    } else {
      try {
        Fields.echoMachine(
            symbols, new Machine.MachineCase(LawSpecRuntime.integer("IntSize", "1099511627776")));
        throw new AssertionError("unchecked machine range");
      } catch (IllegalArgumentException expected) {
        require(expected.getMessage().contains("IntSize"));
      }
    }
    var symbol = LawSpecRuntime.symbol("fixture", "same", symbols);
    var identity = new Identity.IdentityCase(symbol);
    var result = (Identity.IdentityCase) Fields.echoIdentity(symbols, identity);
    require(LawSpecRuntime.equal(symbol, result.value));
    rejected(() -> Fields.echoIdentity(new HashMap<>(), identity));
    rejected(
        () ->
            Fields.echoIdentity(
                symbols,
                new Identity.IdentityCase(LawSpecRuntime.symbol("other", "same", symbols))));
    var list =
        Fields.echoList(
            symbols, List.of(new LawSpecRuntime.Nothing<>(), new LawSpecRuntime.Just<>(identity)));
    require(list.size() == 2);
    var schema = LawSpecDataSchema.create();
    var codec = LawSpecDataCodecs.identityCodec(schema, bits, symbols);
    var logical = codec.encode(identity);
    require(LawSpecRuntime.equal(((Identity.IdentityCase) codec.decode(logical)).value, symbol));
    for (var name : List.of("Nullable", "Optional")) {
      var type = name + " fixture.fields::type::Identity";
      var present = new Value(type, new Presence(true, logical));
      var absent = new Value(type, new Presence(false, null));
      if (name.equals("Nullable")) {
        Fields.echoNullable(symbols, present);
        Fields.echoNullable(symbols, absent);
        rejected(() -> Fields.echoNullable(new HashMap<>(), present));
      } else {
        Fields.echoOptional(symbols, present);
        Fields.echoOptional(symbols, absent);
        rejected(() -> Fields.echoOptional(new HashMap<>(), present));
      }
    }
    var raw = (Raw.RawCase) Fields.echoRaw(symbols, new Raw.RawCase('\ud800'));
    require(raw.value == '\ud800');
    rejected(() -> Fields.echoRaw(symbols, new Raw.RawCase('a')));
    System.out.println("Java native constructor definitions and codecs passed: " + bits);
  }
}
