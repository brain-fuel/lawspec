import java.math.BigInteger;
import java.util.HashMap;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Function;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Data;
import lawspec.runtime.LawSpecRuntime.Presence;
import lawspec.runtime.LawSpecRuntime.Value;
import lawspec.runtime.LawSpecSchema;
import lawspec.runtime.LawSpecSchema.Constructor;
import lawspec.runtime.LawSpecSchema.Definition;
import lawspec.runtime.LawSpecSchema.Field;
import lawspec.runtime.LawSpecSchema.Named;
import lawspec.runtime.LawSpecSchema.Parameter;
import lawspec.runtime.LawSpecSchema.TypeRef;

public final class JavaPayloadCheck {
  static Named n(String name, TypeRef... args) {
    return new Named(name, args);
  }

  static Constructor c(String tag, TypeRef... types) {
    var fields = new java.util.ArrayList<Field>();
    for (int i = 0; i < types.length; i++) fields.add(new Field("field" + i, types[i]));
    return new Constructor(tag, fields);
  }

  static final Named INT = n("Int8");
  static final Named TREE = n("Tree", INT);
  static final Parameter A = new Parameter(0);
  static final Parameter B = new Parameter(1);

  static Value number(int n) {
    return new Value("Int8", BigInteger.valueOf(n));
  }

  static Value data(Named ty, String tag, Value... fields) {
    return new Value(LawSpecSchema.key(ty), new Data(tag, List.of(fields)));
  }

  static Value list(Named element, Value... items) {
    return new Value(LawSpecSchema.key(n("List", element)), List.of(items));
  }

  static Value leaf(int value) {
    return data(TREE, "Tree::Leaf", number(value), number(-128));
  }

  static void require(boolean condition) {
    if (!condition) throw new AssertionError();
  }

  static void fails(Runnable action, String text) {
    try {
      action.run();
    } catch (IllegalArgumentException error) {
      require(error.getMessage().contains(text));
      return;
    }
    throw new AssertionError("expected rejection: " + text);
  }

  static final Function<Value, Value> POSITIVE =
      value -> LawSpecRuntime.bool(((BigInteger) value.data()).signum() > 0);
  static final Function<Value, Value> NEGATIVE =
      value -> LawSpecRuntime.bool(((BigInteger) value.data()).signum() < 0);
  static final Function<Value, Value> UNUSED =
      value -> {
        throw new AssertionError("unstored callback");
      };

  static LawSpecSchema schema() {
    return new LawSpecSchema(
        List.of(
            new Definition(
                "Tree",
                1,
                List.of(c("Tree::Leaf", A, INT), c("Tree::Forest", n("List", n("Tree", A))))),
            new Definition("Pair", 2, List.of(c("Pair::Pair", A, B))),
            new Definition(
                "Nest", 1, List.of(c("Nest::Stop", A), c("Nest::Next", n("Nest", n("List", A))))),
            new Definition("Phantom", 1, List.of(c("Phantom::Tag"))),
            new Definition("A", 2, List.of(c("A::End", A), c("A::Next", n("B", B, A)))),
            new Definition("B", 2, List.of(c("B::End", A), c("B::Next", n("A", B, A)))),
            new Definition(
                "Wrapped",
                1,
                List.of(c("Wrapped::Wrap", n("Nullable", n("Optional", n("List", A)))))),
            new Definition(
                "Checked",
                1,
                List.of(
                    new Constructor(
                        "Checked::Value",
                        List.of(new Field("value", A)),
                        List.of(
                            (schema, args, fields, bits, symbols) ->
                                LawSpecRuntime.truth(POSITIVE.apply(fields.get(0)))))))));
  }

  @SafeVarargs
  static boolean check(
      LawSpecSchema schema, int bits, Named ty, Value value, Function<Value, Value>... predicates) {
    return LawSpecRuntime.truth(
        schema.allPayloads(ty, value, List.of(predicates), bits, new HashMap<>()));
  }

  public static void main(String[] args) {
    int bits = Integer.parseInt(args[0]);
    var schema = schema();
    for (int value : new int[] {1, 0}) {
      var deep = leaf(value);
      for (int depth = 0; depth < 40; depth++) deep = data(TREE, "Tree::Forest", list(TREE, deep));
      require(check(schema, bits, TREE, deep, POSITIVE) == (value > 0));
      var pair = n("Pair", INT, INT);
      require(
          check(
                  schema,
                  bits,
                  pair,
                  data(pair, "Pair::Pair", number(1), number(-value)),
                  POSITIVE,
                  NEGATIVE)
              == (value > 0));
      var root = n("A", INT, INT);
      require(
          check(
                  schema,
                  bits,
                  root,
                  data(root, "A::Next", data(n("B", INT, INT), "B::End", number(-value))),
                  POSITIVE,
                  NEGATIVE)
              == (value > 0));
      var listInt = n("List", INT);
      var nested = data(n("Nest", listInt), "Nest::Stop", list(INT, number(value)));
      require(
          check(schema, bits, n("Nest", INT), data(n("Nest", INT), "Nest::Next", nested), POSITIVE)
              == (value > 0));
      var optional =
          new Value(
              LawSpecSchema.key(n("Optional", listInt)),
              new Presence(true, list(INT, number(value))));
      var nullable =
          new Value(
              LawSpecSchema.key(n("Nullable", n("Optional", listInt))),
              new Presence(true, optional));
      var wrapped = n("Wrapped", INT);
      require(
          check(schema, bits, wrapped, data(wrapped, "Wrapped::Wrap", nullable), POSITIVE)
              == (value > 0));
    }
    require(check(schema, bits, TREE, data(TREE, "Tree::Forest", list(TREE)), UNUSED));
    var phantom = n("Phantom", INT);
    require(check(schema, bits, phantom, data(phantom, "Phantom::Tag"), UNUSED));
    var maybe = n("Maybe", INT);
    require(check(schema, bits, maybe, data(maybe, "Maybe::Nothing"), UNUSED));
    var either = n("Either", INT, INT);
    require(
        check(schema, bits, either, data(either, "Either::Right", number(1)), UNUSED, POSITIVE));
    for (String kind : List.of("Nullable", "Optional")) {
      var ty = n(kind, INT);
      require(
          check(
              schema,
              bits,
              ty,
              new Value(LawSpecSchema.key(ty), new Presence(false, null)),
              UNUSED));
    }
    var optionalType = n("Optional", INT);
    var optionalValue = new Value(LawSpecSchema.key(optionalType), new Presence(false, null));
    var treeOfOptional = n("Tree", optionalType);
    require(
        check(
            schema,
            bits,
            treeOfOptional,
            data(treeOfOptional, "Tree::Leaf", optionalValue, number(0)),
            value -> LawSpecRuntime.bool(value.data() instanceof Presence)));
    var visits = new AtomicInteger();
    require(
        !check(
            schema,
            bits,
            TREE,
            data(TREE, "Tree::Forest", list(TREE, leaf(0), leaf(1))),
            value -> {
              visits.incrementAndGet();
              return POSITIVE.apply(value);
            }));
    require(visits.get() == 1);
    fails(
        () ->
            check(
                schema,
                bits,
                TREE,
                leaf(1),
                value -> {
                  throw new IllegalStateException("fault");
                }),
        "Tree::Leaf.field0: fault");
    fails(() -> check(schema, bits, TREE, leaf(1), value -> number(1)), "Bool");
    fails(
        () ->
            check(
                schema,
                bits,
                TREE,
                data(TREE, "Tree::Leaf", number(1), number(128)),
                value -> LawSpecRuntime.bool(true)),
        "field1");
    fails(() -> check(schema, bits, TREE, leaf(1)), "arity");
    fails(() -> check(schema, bits, INT, number(1)), "data type");
    var checked = n("Checked", INT);
    fails(
        () -> check(schema, bits, checked, data(checked, "Checked::Value", number(0)), UNUSED),
        "field refinement 1 failed");
    System.out.println("Java payload traversal passed at " + bits + " bits");
  }
}
