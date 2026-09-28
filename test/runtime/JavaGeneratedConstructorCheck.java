import java.util.HashMap;
import java.util.List;
import java.util.Map;
import lawspec.runtime.LawSpecDataSchema;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Data;
import lawspec.runtime.LawSpecRuntime.Value;
import lawspec.runtime.LawSpecSchema;
import lawspec.runtime.LawSpecSchema.Named;

public final class JavaGeneratedConstructorCheck {
  private static final String PREFIX = "native.fields::type::";
  private static int bits;
  private static final Map<String, Object> SYMBOLS = new HashMap<>();
  private static final LawSpecSchema SCHEMA = LawSpecDataSchema.create();

  private static void require(boolean condition) {
    if (!condition) throw new AssertionError();
  }

  private static Named named(String name, Named... arguments) {
    return new Named(PREFIX + name, (LawSpecSchema.TypeRef[]) arguments);
  }

  private static Value integer(int value) {
    return LawSpecRuntime.integer("Int8", Integer.toString(value));
  }

  private static Value data(Named type, String tag, Value... fields) {
    return new Value(LawSpecSchema.key(type), new Data(type.name() + "::" + tag, List.of(fields)));
  }

  private static void accepted(Named type, String tag, Value... fields) {
    SCHEMA.validate(type, data(type, tag, fields), bits, SYMBOLS);
  }

  private static void rejected(Named type, String tag, Value... fields) {
    require(
        SCHEMA.check(type, data(type, tag, fields), bits, SYMBOLS)
            instanceof LawSpecSchema.Rejected);
  }

  public static void main(String[] args) {
    bits = Integer.parseInt(args[0]);
    accepted(named("Gap"), "Gap", integer(-128), integer(127));
    rejected(named("Gap"), "Gap", integer(0), integer(0));
    rejected(named("Gap"), "Gap", integer(127), integer(-128));
    var symbol = LawSpecRuntime.symbol("fixture", "same", SYMBOLS);
    accepted(named("Identity"), "Identity", symbol);
    rejected(named("Identity"), "Identity", LawSpecRuntime.symbol("different", "same", SYMBOLS));
    var integers = new Named("List", new Named("Int8"));
    accepted(
        named("Bucket", new Named("Int8")),
        "Bucket",
        new Value(LawSpecSchema.key(integers), List.of(integer(1))));
    rejected(
        named("Bucket", new Named("Int8")),
        "Bucket",
        new Value(LawSpecSchema.key(integers), List.of()));
    accepted(
        named("Positives"),
        "Positives",
        new Value(LawSpecSchema.key(integers), List.of(integer(1), integer(2))));
    rejected(
        named("Positives"),
        "Positives",
        new Value(LawSpecSchema.key(integers), List.of(integer(1), integer(0))));
    accepted(named("Choice"), "Accepted", integer(1));
    rejected(named("Choice"), "Accepted", integer(0));
    accepted(named("Choice"), "Rejected", LawSpecRuntime.sequence("Text", new int[] {110, 111}));
    accepted(named("Guarded"), "Guarded", integer(2));
    rejected(named("Guarded"), "Guarded", integer(0));
    rejected(named("Guarded"), "Guarded", integer(-1));
    accepted(named("Machine"), "Machine", LawSpecRuntime.integer("IntSize", "1"));
    rejected(named("Machine"), "Machine", LawSpecRuntime.integer("IntSize", "0"));
    for (var element : List.of(new Named("Int8"), named("Identity"))) {
      var maybe = new Named("Maybe", element);
      var payload = element.name().equals("Int8") ? integer(1) : data(element, "Identity", symbol);
      var value = SCHEMA.construct(maybe, "Maybe::Just", List.of(payload), bits, SYMBOLS);
      accepted(named("HasValue", element), "HasValue", value);
      rejected(
          named("HasValue", element),
          "HasValue",
          SCHEMA.construct(maybe, "Maybe::Nothing", List.of(), bits, SYMBOLS));
    }
    var rows = new Named("List", integers);
    accepted(
        named("Nested"),
        "Nested",
        new Value(
            LawSpecSchema.key(rows),
            List.of(
                new Value(LawSpecSchema.key(integers), List.of()),
                new Value(LawSpecSchema.key(integers), List.of(integer(1))))));
    rejected(
        named("Nested"),
        "Nested",
        new Value(
            LawSpecSchema.key(rows),
            List.of(new Value(LawSpecSchema.key(integers), List.of(integer(0))))));
    System.out.println("Java source-derived constructor callbacks passed: " + bits);
  }
}
