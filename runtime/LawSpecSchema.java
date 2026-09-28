package lawspec.runtime;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;
import lawspec.runtime.LawSpecRuntime.Data;
import lawspec.runtime.LawSpecRuntime.Presence;
import lawspec.runtime.LawSpecRuntime.Value;

/** Runtime metadata derived from checked Core, independent of testing frameworks. */
public final class LawSpecSchema {
  public sealed interface TypeRef permits Parameter, Named {}

  public record Parameter(int index) implements TypeRef {
    public Parameter {
      if (index < 0) throw new IllegalArgumentException("negative schema parameter");
    }
  }

  public record Named(String name, List<TypeRef> arguments) implements TypeRef {
    public Named {
      arguments = List.copyOf(arguments);
    }

    public Named(String name, TypeRef... arguments) {
      this(name, List.of(arguments));
    }
  }

  public record Field(String name, TypeRef type) {}

  @FunctionalInterface
  public interface FieldPredicate {
    boolean test(
        LawSpecSchema schema,
        List<TypeRef> arguments,
        List<Value> fields,
        int bits,
        Map<String, Object> symbols);
  }

  public static final class RefinementViolation extends IllegalArgumentException {
    public RefinementViolation(String message) {
      super(message);
    }

    private RefinementViolation(String message, Throwable cause) {
      super(message, cause);
    }
  }

  public sealed interface ValueCheck permits Accepted, Rejected {}

  public record Accepted(Value value) implements ValueCheck {}

  public record Rejected(String reason) implements ValueCheck {}

  public record Constructor(String tag, List<Field> fields, List<FieldPredicate> predicates) {
    public Constructor {
      fields = List.copyOf(fields);
      predicates = List.copyOf(predicates);
    }

    public Constructor(String tag, List<Field> fields) {
      this(tag, fields, List.of());
    }
  }

  public record Definition(String name, int parameters, List<Constructor> constructors) {
    public Definition {
      if (parameters < 0) throw new IllegalArgumentException("negative parameter count");
      constructors = List.copyOf(constructors);
    }
  }

  private static final Set<String> SCALARS =
      Set.of(
          "Bool",
          "Int8",
          "Int16",
          "Int32",
          "Int64",
          "UInt8",
          "UInt16",
          "UInt32",
          "UInt64",
          "IntSize",
          "UIntSize",
          "UIntPtr",
          "Integer",
          "BigInt",
          "BigUInt",
          "Decimal",
          "Rational",
          "Float32",
          "Float64",
          "Complex64",
          "Complex128",
          "Char",
          "CodePoint",
          "CodeUnit16",
          "Text",
          "CodePointText",
          "Utf16Text",
          "Bytes",
          "Symbol",
          "Unit",
          "Null",
          "Undefined");
  private static final Map<String, Integer> CONTAINERS =
      Map.of("List", 1, "Maybe", 1, "Either", 2, "Nullable", 1, "Optional", 1);
  private final Map<String, Definition> definitions;

  public LawSpecSchema(List<Definition> declarations) {
    var table = new HashMap<String, Definition>();
    var tags = new HashSet<String>();
    for (var definition : declarations) {
      if (SCALARS.contains(definition.name())
          || CONTAINERS.containsKey(definition.name())
          || table.putIfAbsent(definition.name(), definition) != null) {
        throw new IllegalArgumentException("duplicate schema type: " + definition.name());
      }
      for (var constructor : definition.constructors()) {
        if (!tags.add(constructor.tag()))
          throw new IllegalArgumentException("duplicate constructor tag");
      }
    }
    definitions = Map.copyOf(table);
    for (var definition : declarations) {
      for (var constructor : definition.constructors()) {
        var names = new HashSet<String>();
        for (var field : constructor.fields()) {
          if (!names.add(field.name())) throw new IllegalArgumentException("duplicate field name");
          checkType(field.type(), definition.parameters());
        }
      }
    }
  }

  public boolean hasContracts() {
    return definitions.values().stream()
        .flatMap(definition -> definition.constructors().stream())
        .anyMatch(constructor -> !constructor.predicates().isEmpty());
  }

  private void checkType(TypeRef type, int parameters) {
    if (type instanceof Parameter variable) {
      if (variable.index() >= parameters)
        throw new IllegalArgumentException("unbound schema parameter");
      return;
    }
    if (!(type instanceof Named named)) throw new IllegalArgumentException("missing schema type");
    var definition = definitions.get(named.name());
    int arity =
        definition != null
            ? definition.parameters()
            : CONTAINERS.getOrDefault(named.name(), SCALARS.contains(named.name()) ? 0 : -1);
    if (arity < 0 || named.arguments().size() != arity) {
      throw new IllegalArgumentException("invalid schema type application: " + named.name());
    }
    for (var argument : named.arguments()) checkType(argument, parameters);
  }

  public TypeRef substitute(TypeRef type, List<TypeRef> arguments) {
    if (type instanceof Parameter variable) {
      if (variable.index() >= arguments.size())
        throw new IllegalArgumentException("unbound schema parameter");
      return arguments.get(variable.index());
    }
    var named = (Named) type;
    return new Named(
        named.name(),
        named.arguments().stream().map(argument -> substitute(argument, arguments)).toList());
  }

  public boolean isScalar(Named type) {
    checkType(type, 0);
    return SCALARS.contains(type.name());
  }

  public List<String> constructors(Named type) {
    checkType(type, 0);
    var definition = definitions.get(type.name());
    if (definition != null)
      return definition.constructors().stream().map(Constructor::tag).toList();
    return switch (type.name()) {
      case "Maybe" -> List.of("Maybe::Nothing", "Maybe::Just");
      case "Either" -> List.of("Either::Left", "Either::Right");
      default -> throw new IllegalArgumentException("algebraic type required");
    };
  }

  public List<Field> fields(Named type, String tag) {
    checkType(type, 0);
    var definition = definitions.get(type.name());
    if (definition != null) {
      for (var constructor : definition.constructors()) {
        if (constructor.tag().equals(tag))
          return constructor.fields().stream()
              .map(field -> new Field(field.name(), substitute(field.type(), type.arguments())))
              .toList();
      }
    } else if (type.name().equals("Maybe")) {
      if (tag.equals("Maybe::Nothing")) return List.of();
      if (tag.equals("Maybe::Just")) return List.of(new Field("value", type.arguments().get(0)));
    } else if (type.name().equals("Either")) {
      if (tag.equals("Either::Left")) return List.of(new Field("value", type.arguments().get(0)));
      if (tag.equals("Either::Right")) return List.of(new Field("value", type.arguments().get(1)));
    }
    throw new IllegalArgumentException("constructor " + tag + " does not belong to " + type.name());
  }

  public static String key(TypeRef type) {
    if (!(type instanceof Named named))
      throw new IllegalArgumentException("unbound schema parameter");
    if (named.arguments().isEmpty()) return named.name();
    if (named.arguments().size() == 1 && CONTAINERS.containsKey(named.name())) {
      return named.name() + " " + key(named.arguments().get(0));
    }
    var result = new StringBuilder(named.name());
    for (var argument : named.arguments()) result.append(" (").append(key(argument)).append(")");
    return result.toString();
  }

  private sealed interface PayloadPlan permits IgnorePayload, PayloadSlot, PayloadApplication {}

  private enum IgnorePayload implements PayloadPlan {
    INSTANCE
  }

  private record PayloadSlot(int index) implements PayloadPlan {}

  private record PayloadApplication(String name, List<PayloadPlan> arguments)
      implements PayloadPlan {}

  private static PayloadPlan payloadRecipe(TypeRef type, List<PayloadPlan> arguments) {
    if (type instanceof Parameter parameter) return arguments.get(parameter.index());
    var named = (Named) type;
    var children =
        named.arguments().stream().map(child -> payloadRecipe(child, arguments)).toList();
    return children.stream().allMatch(child -> child == IgnorePayload.INSTANCE)
        ? IgnorePayload.INSTANCE
        : new PayloadApplication(named.name(), children);
  }

  /** Check stored type arguments after full value and constructor-contract validation. */
  public Value allPayloads(
      Named type,
      Value value,
      List<Function<Value, Value>> predicates,
      int bits,
      Map<String, Object> symbols) {
    checkType(type, 0);
    if (!definitions.containsKey(type.name()) && !CONTAINERS.containsKey(type.name()))
      throw new IllegalArgumentException("payload predicates require a data type");
    predicates = List.copyOf(predicates);
    if (predicates.size() != type.arguments().size())
      throw new IllegalArgumentException("payload predicate arity mismatch");
    var checked = validate(type, value, bits, symbols);
    var arguments = new ArrayList<PayloadPlan>();
    for (int index = 0; index < predicates.size(); index++) arguments.add(new PayloadSlot(index));
    return LawSpecRuntime.bool(
        walkPayload(new PayloadApplication(type.name(), arguments), checked, predicates));
  }

  private boolean contextualPayload(
      PayloadPlan plan, Value value, List<Function<Value, Value>> predicates, String context) {
    try {
      return walkPayload(plan, value, predicates);
    } catch (RuntimeException error) {
      throw new IllegalArgumentException(context + ": " + error.getMessage(), error);
    }
  }

  private boolean walkPayload(
      PayloadPlan plan, Value value, List<Function<Value, Value>> predicates) {
    if (plan == IgnorePayload.INSTANCE) return true;
    if (plan instanceof PayloadSlot slot)
      return LawSpecRuntime.truth(predicates.get(slot.index()).apply(value));
    var application = (PayloadApplication) plan;
    var arguments = application.arguments();
    var name = application.name();
    if (name.equals("List")) {
      var values = (List<?>) value.data();
      for (int index = 0; index < values.size(); index++)
        if (!contextualPayload(
            arguments.get(0), (Value) values.get(index), predicates, "List[" + index + "]"))
          return false;
      return true;
    }
    if (name.equals("Nullable") || name.equals("Optional")) {
      var presence = (Presence) value.data();
      return !presence.present()
          || contextualPayload(arguments.get(0), presence.value(), predicates, name + ".value");
    }
    var data = (Data) value.data();
    if (name.equals("Maybe"))
      return data.tag().equals("Maybe::Nothing")
          || contextualPayload(
              arguments.get(0), data.fields().get(0), predicates, "Maybe::Just.value");
    if (name.equals("Either")) {
      int index = data.tag().equals("Either::Left") ? 0 : 1;
      return contextualPayload(
          arguments.get(index), data.fields().get(0), predicates, data.tag() + ".value");
    }
    var constructor =
        definitions.get(name).constructors().stream()
            .filter(candidate -> candidate.tag().equals(data.tag()))
            .findFirst()
            .orElseThrow();
    for (int index = 0; index < constructor.fields().size(); index++) {
      var field = constructor.fields().get(index);
      if (!contextualPayload(
          payloadRecipe(field.type(), arguments),
          data.fields().get(index),
          predicates,
          data.tag() + "." + field.name())) return false;
    }
    return true;
  }

  public Value validate(Named type, Value value, int bits) {
    return validate(type, value, bits, new HashMap<>());
  }

  public ValueCheck check(Named type, Value value, int bits, Map<String, Object> symbols) {
    try {
      return new Accepted(validate(type, value, bits, symbols));
    } catch (RefinementViolation rejected) {
      return new Rejected(rejected.getMessage());
    }
  }

  public Value validate(Named type, Value value, int bits, Map<String, Object> symbols) {
    checkType(type, 0);
    if (bits != 32 && bits != 64)
      throw new IllegalArgumentException("machineBits must be 32 or 64");
    if (value == null || !key(type).equals(value.type())) {
      throw new IllegalArgumentException("invalid " + key(type) + " representation");
    }
    if (definitions.containsKey(type.name())
        || type.name().equals("Maybe")
        || type.name().equals("Either")) {
      if (!(value.data() instanceof Data data))
        throw new IllegalArgumentException("tagged data required");
      var types = fields(type, data.tag());
      if (types.size() != data.fields().size())
        throw new IllegalArgumentException("invalid constructor arity");
      var checked = new ArrayList<Value>();
      for (int index = 0; index < types.size(); index++) {
        var field = types.get(index);
        checked.add(
            validateField(
                (Named) field.type(),
                data.fields().get(index),
                bits,
                data.tag() + "." + field.name(),
                symbols));
      }
      var definition = definitions.get(type.name());
      if (definition != null) {
        var constructor =
            definition.constructors().stream()
                .filter(candidate -> candidate.tag().equals(data.tag()))
                .findFirst()
                .orElseThrow();
        var logical = List.copyOf(checked);
        for (int index = 0; index < constructor.predicates().size(); index++) {
          boolean accepted;
          String context = data.tag() + ": field refinement " + (index + 1);
          try {
            accepted =
                constructor
                    .predicates()
                    .get(index)
                    .test(this, type.arguments(), logical, bits, symbols);
          } catch (RuntimeException error) {
            throw new IllegalArgumentException(context + ": " + error.getMessage(), error);
          }
          if (!accepted) throw new RefinementViolation(context + " failed");
        }
      }
      return new Value(key(type), new Data(data.tag(), checked));
    }
    if (type.name().equals("List")) {
      if (!(value.data() instanceof List<?> items))
        throw new IllegalArgumentException("list required");
      var checked = new ArrayList<Value>();
      for (int index = 0; index < items.size(); index++) {
        if (!(items.get(index) instanceof Value element))
          throw new IllegalArgumentException("invalid list element");
        checked.add(
            validateField(
                (Named) type.arguments().get(0), element, bits, "[" + index + "]", symbols));
      }
      return new Value(key(type), List.copyOf(checked));
    }
    if (type.name().equals("Nullable") || type.name().equals("Optional")) {
      if (!(value.data() instanceof Presence p))
        throw new IllegalArgumentException("tagged presence required");
      if (!p.present() && p.value() != null)
        throw new IllegalArgumentException("absent payload must be empty");
      return new Value(
          key(type),
          new Presence(
              p.present(),
              p.present()
                  ? validateField(
                      (Named) type.arguments().get(0), p.value(), bits, "present", symbols)
                  : null));
    }
    return LawSpecRuntime.validate(type.name(), value, bits);
  }

  private Value validateField(
      Named type, Value value, int bits, String context, Map<String, Object> symbols) {
    try {
      return validate(type, value, bits, symbols);
    } catch (RefinementViolation error) {
      throw new RefinementViolation(context + ": " + error.getMessage(), error);
    } catch (IllegalArgumentException | ArithmeticException error) {
      throw new IllegalArgumentException(context + ": " + error.getMessage(), error);
    }
  }

  public Value construct(Named type, String tag, List<Value> fields, int bits) {
    return construct(type, tag, fields, bits, new HashMap<>());
  }

  public Value construct(
      Named type, String tag, List<Value> fields, int bits, Map<String, Object> symbols) {
    return validate(type, new Value(key(type), new Data(tag, fields)), bits, symbols);
  }

  public Value match(Named type, Value value, int bits, Function<Data, Value> branch) {
    return match(type, value, bits, new HashMap<>(), branch);
  }

  public Value match(
      Named type,
      Value value,
      int bits,
      Map<String, Object> symbols,
      Function<Data, Value> branch) {
    var checked = validate(type, value, bits, symbols);
    if (!(checked.data() instanceof Data data))
      throw new IllegalArgumentException("algebraic data required");
    return branch.apply(data);
  }

  public boolean equal(Named type, Value left, Value right, int bits) {
    return equal(type, left, right, bits, new HashMap<>());
  }

  public boolean equal(Named type, Value left, Value right, int bits, Map<String, Object> symbols) {
    return equalValidated(
        validate(type, left, bits, symbols), validate(type, right, bits, symbols));
  }

  /** A native bridge always validates before decoding and after encoding. */
  public interface Codec<T> {
    Named type();

    Value encode(T value);

    T decode(Value value);
  }

  public <T> Codec<T> codec(
      Named type, int bits, Function<T, Value> encode, Function<Value, T> decode) {
    return codec(type, bits, new HashMap<>(), encode, decode);
  }

  public <T> Codec<T> codec(
      Named type,
      int bits,
      Map<String, Object> symbols,
      Function<T, Value> encode,
      Function<Value, T> decode) {
    checkType(type, 0);
    if (bits != 32 && bits != 64)
      throw new IllegalArgumentException("machineBits must be 32 or 64");
    return new Codec<>() {
      public Named type() {
        return type;
      }

      public Value encode(T value) {
        return validate(type, encode.apply(value), bits, symbols);
      }

      public T decode(Value value) {
        return decode.apply(validate(type, value, bits, symbols));
      }
    };
  }

  public static <T> Value encodeField(Codec<T> codec, T value, String context) {
    try {
      return codec.encode(value);
    } catch (RefinementViolation error) {
      throw new RefinementViolation(context + ": " + error.getMessage(), error);
    } catch (IllegalArgumentException | ArithmeticException | ClassCastException error) {
      throw new IllegalArgumentException(context + ": " + error.getMessage(), error);
    }
  }

  public <T> Codec<T> scalar(String name, int bits, Class<T> nativeClass) {
    if (!SCALARS.contains(name)) throw new IllegalArgumentException("scalar type required");
    return codec(
        new Named(name),
        bits,
        value -> LawSpecRuntime.fromNative(name, nativeClass.cast(value), bits),
        value -> nativeClass.cast(LawSpecRuntime.toNative(name, value, bits)));
  }

  public Codec<Value> supported(Named type, int bits) {
    return supported(type, bits, new HashMap<>());
  }

  public Codec<Value> supported(Named type, int bits, Map<String, Object> symbols) {
    return codec(type, bits, symbols, Function.identity(), Function.identity());
  }

  public <T> Codec<List<T>> list(Codec<T> element, int bits) {
    return list(element, bits, new HashMap<>());
  }

  public <T> Codec<List<T>> list(Codec<T> element, int bits, Map<String, Object> symbols) {
    var type = new Named("List", element.type());
    return codec(
        type,
        bits,
        symbols,
        values -> new Value(key(type), values.stream().map(element::encode).toList()),
        value -> {
          var values = new ArrayList<T>();
          for (var item : (List<?>) value.data()) values.add(element.decode((Value) item));
          return values;
        });
  }

  public <T> Codec<LawSpecRuntime.Maybe<T>> maybe(Codec<T> element, int bits) {
    return maybe(element, bits, new HashMap<>());
  }

  public <T> Codec<LawSpecRuntime.Maybe<T>> maybe(
      Codec<T> element, int bits, Map<String, Object> symbols) {
    var type = new Named("Maybe", element.type());
    return codec(
        type,
        bits,
        symbols,
        value ->
            switch (value) {
              case LawSpecRuntime.Nothing<T> ignored ->
                  construct(type, "Maybe::Nothing", List.of(), bits, symbols);
              case LawSpecRuntime.Just<T> just ->
                  construct(
                      type, "Maybe::Just", List.of(element.encode(just.value())), bits, symbols);
            },
        value -> {
          var data = (Data) value.data();
          return data.tag().equals("Maybe::Nothing")
              ? new LawSpecRuntime.Nothing<>()
              : new LawSpecRuntime.Just<>(element.decode(data.fields().get(0)));
        });
  }

  public <L, R> Codec<LawSpecRuntime.Either<L, R>> either(Codec<L> left, Codec<R> right, int bits) {
    return either(left, right, bits, new HashMap<>());
  }

  public <L, R> Codec<LawSpecRuntime.Either<L, R>> either(
      Codec<L> left, Codec<R> right, int bits, Map<String, Object> symbols) {
    var type = new Named("Either", left.type(), right.type());
    return codec(
        type,
        bits,
        symbols,
        value ->
            switch (value) {
              case LawSpecRuntime.Left<L, R> item ->
                  construct(
                      type, "Either::Left", List.of(left.encode(item.value())), bits, symbols);
              case LawSpecRuntime.Right<L, R> item ->
                  construct(
                      type, "Either::Right", List.of(right.encode(item.value())), bits, symbols);
            },
        value -> {
          var data = (Data) value.data();
          return data.tag().equals("Either::Left")
              ? new LawSpecRuntime.Left<>(left.decode(data.fields().get(0)))
              : new LawSpecRuntime.Right<>(right.decode(data.fields().get(0)));
        });
  }

  private boolean equalValidated(Value left, Value right) {
    if (left.data() instanceof Data a && right.data() instanceof Data b) {
      if (!a.tag().equals(b.tag()) || a.fields().size() != b.fields().size()) return false;
      for (int index = 0; index < a.fields().size(); index++) {
        if (!equalValidated(a.fields().get(index), b.fields().get(index))) return false;
      }
      return true;
    }
    if (left.type().startsWith("List ")) {
      var a = (List<?>) left.data();
      var b = (List<?>) right.data();
      if (a.size() != b.size()) return false;
      for (int index = 0; index < a.size(); index++) {
        if (!equalValidated((Value) a.get(index), (Value) b.get(index))) return false;
      }
      return true;
    }
    if (left.data() instanceof Presence a && right.data() instanceof Presence b) {
      return a.present() == b.present() && (!a.present() || equalValidated(a.value(), b.value()));
    }
    return LawSpecRuntime.equal(left, right);
  }
}
