import java.math.BigInteger;
import java.util.HashMap;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Data;
import lawspec.runtime.LawSpecRuntime.Presence;
import lawspec.runtime.LawSpecRuntime.Value;
import lawspec.runtime.LawSpecSchema;
import lawspec.runtime.LawSpecSchema.Constructor;
import lawspec.runtime.LawSpecSchema.Definition;
import lawspec.runtime.LawSpecSchema.Field;
import lawspec.runtime.LawSpecSchema.FieldPredicate;
import lawspec.runtime.LawSpecSchema.Named;
import lawspec.runtime.LawSpecSchema.Parameter;

public final class JavaConstructorContractsCheck {
  private static void require(boolean condition) {
    if (!condition) throw new AssertionError();
  }

  private static void error(Runnable action, String text) {
    try {
      action.run();
    } catch (IllegalArgumentException expected) {
      require(!(expected instanceof LawSpecSchema.RefinementViolation));
      require(expected.getMessage().contains(text));
      return;
    }
    throw new AssertionError("expected evaluator/representation error");
  }

  private static LawSpecSchema box(List<FieldPredicate> predicates) {
    return new LawSpecSchema(
        List.of(
            new Definition(
                "Box",
                1,
                List.of(
                    new Constructor(
                        "Box", List.of(new Field("value", new Parameter(0))), predicates)))));
  }

  private static Value boxed(Named type, Value value) {
    return new Value(LawSpecSchema.key(type), new Data("Box", List.of(value)));
  }

  public static void main(String[] args) {
    int bits = Integer.parseInt(args[0]);
    var symbols = new HashMap<String, Object>();
    var positive =
        box(
            List.of(
                (schema, types, fields, width, context) -> {
                  require(width == bits);
                  require(schema.substitute(new Parameter(0), types).equals(types.get(0)));
                  return ((BigInteger) fields.get(0).data()).signum() > 0;
                }));
    require(positive.hasContracts());
    require(!box(List.of()).hasContracts());
    var machine = new Named("Box", new Named("IntSize"));
    var one = boxed(machine, LawSpecRuntime.integer("IntSize", "1"));
    require(positive.check(machine, one, bits, symbols) instanceof LawSpecSchema.Accepted);
    require(
        positive.check(
                machine, boxed(machine, LawSpecRuntime.integer("IntSize", "0")), bits, symbols)
            instanceof LawSpecSchema.Rejected);
    var large = boxed(machine, LawSpecRuntime.integer("IntSize", "1099511627776"));
    if (bits == 32) error(() -> positive.check(machine, large, bits, symbols), "Box.value");
    else require(positive.check(machine, large, bits, symbols) instanceof LawSpecSchema.Accepted);
    error(() -> positive.check(machine, new Value("Bool", true), bits, symbols), "representation");

    var visits = new AtomicInteger();
    FieldPredicate broken =
        (schema, types, fields, width, context) -> {
          visits.incrementAndGet();
          throw new ArithmeticException("zero denominator");
        };
    var ordered = box(List.of((schema, types, fields, width, context) -> false, broken));
    require(ordered.check(machine, one, bits, symbols) instanceof LawSpecSchema.Rejected);
    require(visits.get() == 0);
    var failing = box(List.of(broken));
    error(() -> failing.check(machine, one, bits, symbols), "field refinement 1: zero denominator");
    require(visits.get() == 1);
    var listMachine = new Named("List", machine);
    var nestedBad =
        new Value(
            LawSpecSchema.key(listMachine),
            List.of(boxed(machine, LawSpecRuntime.integer("IntSize", "0"))));
    var rejection = (LawSpecSchema.Rejected) positive.check(listMachine, nestedBad, bits, symbols);
    require(rejection.reason().contains("[0]: Box: field refinement"));

    var identity =
        box(
            List.of(
                (schema, types, fields, width, context) ->
                    LawSpecRuntime.equal(
                        fields.get(0), LawSpecRuntime.symbol("fixture", "same", context))));
    var symbolType = new Named("Box", new Named("Symbol"));
    var symbol = LawSpecRuntime.symbol("fixture", "same", symbols);
    var value = boxed(symbolType, symbol);
    require(identity.check(symbolType, value, bits, symbols) instanceof LawSpecSchema.Accepted);
    require(
        identity.check(symbolType, value, bits, new HashMap<>()) instanceof LawSpecSchema.Rejected);
    require(
        identity.check(
                symbolType,
                boxed(symbolType, LawSpecRuntime.symbol("different", "same", symbols)),
                bits,
                symbols)
            instanceof LawSpecSchema.Rejected);
    require(identity.equal(symbolType, value, value, bits, symbols));
    require(
        identity.match(symbolType, value, bits, symbols, data -> data.fields().get(0)) == symbol);
    var codec = identity.supported(symbolType, bits, symbols);
    require(identity.equal(symbolType, value, codec.decode(codec.encode(value)), bits, symbols));
    var list = identity.list(codec, bits, symbols);
    require(list.decode(list.encode(List.of(value))).size() == 1);
    var maybe = identity.maybe(codec, bits, symbols);
    require(
        maybe.decode(maybe.encode(new LawSpecRuntime.Just<>(value)))
            instanceof LawSpecRuntime.Just<?>);
    var either = identity.either(codec, codec, bits, symbols);
    require(
        either.decode(either.encode(new LawSpecRuntime.Right<>(value)))
            instanceof LawSpecRuntime.Right<?, ?>);
    for (var name : List.of("Nullable", "Optional")) {
      var type = new Named(name, symbolType);
      var present = new Value(LawSpecSchema.key(type), new Presence(true, value));
      require(identity.check(type, present, bits, symbols) instanceof LawSpecSchema.Accepted);
      require(
          identity.check(type, present, bits, new HashMap<>()) instanceof LawSpecSchema.Rejected);
      require(
          identity.check(
                  type,
                  new Value(LawSpecSchema.key(type), new Presence(false, null)),
                  bits,
                  symbols)
              instanceof LawSpecSchema.Accepted);
    }

    var raw =
        box(
            List.of(
                (schema, types, values, width, context) -> {
                  require(values.get(0).type().equals("CodeUnit16"));
                  return values.get(0).data().equals(0xd800);
                }));
    var rawType = new Named("Box", new Named("CodeUnit16"));
    var rawCodec =
        raw.codec(
            rawType,
            bits,
            symbols,
            (Character unit) -> boxed(rawType, LawSpecRuntime.character("CodeUnit16", unit)),
            item -> (char) (int) (Integer) ((Data) item.data()).fields().get(0).data());
    require(rawCodec.decode(rawCodec.encode('\ud800')) == '\ud800');
    error(
        () -> raw.substitute(new Parameter(1), List.of(new Named("Bool"))),
        "unbound schema parameter");

    var gap =
        new LawSpecSchema(
            List.of(
                new Definition(
                    "Gap",
                    0,
                    List.of(
                        new Constructor(
                            "Gap",
                            List.of(
                                new Field("first", new Named("Int8")),
                                new Field("second", new Named("Int8"))),
                            List.of(
                                (schema, types, fields, width, context) ->
                                    ((BigInteger) fields.get(1).data())
                                            .compareTo((BigInteger) fields.get(0).data())
                                        > 0))))));
    var gapType = new Named("Gap");
    var fields =
        List.of(LawSpecRuntime.integer("Int8", "-128"), LawSpecRuntime.integer("Int8", "127"));
    require(
        gap.check(gapType, gap.construct(gapType, "Gap", fields, bits, symbols), bits, symbols)
            instanceof LawSpecSchema.Accepted);
    require(
        gap.check(
                gapType,
                new Value("Gap", new Data("Gap", List.of(fields.get(0), fields.get(0)))),
                bits,
                symbols)
            instanceof LawSpecSchema.Rejected);
    System.out.println(
        "Java constructor contracts, classified errors and context-aware codecs passed: " + bits);
  }
}
