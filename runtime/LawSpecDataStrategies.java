package lawspec.testing;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.function.Predicate;
import lawspec.runtime.LawSpecRuntime.Data;
import lawspec.runtime.LawSpecRuntime.Presence;
import lawspec.runtime.LawSpecRuntime.Value;
import lawspec.runtime.LawSpecSchema;
import lawspec.runtime.LawSpecSchema.Named;
import org.jetbrains.jetCheck.Generator;
import org.jetbrains.jetCheck.IntDistribution;

/** Native JetCheck generation and shrinking for the checked data schema. */
public final class LawSpecDataStrategies {
  private LawSpecDataStrategies() {}

  @FunctionalInterface
  public interface NativeFactory {
    Generator<Value> create(
        LawSpecSchema schema,
        Named type,
        int bits,
        Map<String, Object> symbols,
        List<Generator<Value>> arguments);
  }

  /** Conversion failures are values at the checked property boundary, even on replay. */
  private static final class NativeFailure extends IllegalArgumentException {
    NativeFailure(Named type, RuntimeException cause) {
      super("native generator " + LawSpecSchema.key(type) + ": " + cause.getMessage(), cause);
    }
  }

  public static <T> Generator<Value> nativeValues(
      LawSpecSchema.Codec<T> codec, Generator<T> source) {
    return source.map(
        value -> {
          try {
            return codec.encode(value);
          } catch (RuntimeException error) {
            throw new NativeFailure(codec.type(), error);
          }
        });
  }

  public static <T> Generator<T> nativeArguments(
      LawSpecSchema.Codec<T> codec, Generator<Value> source) {
    return source.map(
        value -> {
          try {
            return codec.decode(value);
          } catch (RuntimeException error) {
            throw new NativeFailure(codec.type(), error);
          }
        });
  }

  public record Captured<T>(T value, RuntimeException error) {
    public T requireValue() {
      if (error != null) throw error;
      return value;
    }
  }

  /** Carry native conversion errors across composed draws to the property callback. */
  public static <T> Generator<Captured<T>> capture(Generator<T> source) {
    return Generator.from(
        environment -> {
          try {
            return new Captured<>(environment.generate(source), null);
          } catch (NativeFailure error) {
            return new Captured<>(null, error);
          }
        });
  }

  public static Generator<Value> generator(
      LawSpecSchema schema,
      Named type,
      int bits,
      int nodeBudget,
      Function<String, Generator<Value>> scalar) {
    return new Builder(schema, bits, scalar).generate(type, nodeBudget);
  }

  public static Generator<Value> sizedGenerator(
      LawSpecSchema schema,
      Named type,
      int bits,
      int minimumBudget,
      Function<String, Generator<Value>> scalar) {
    var builder = new Builder(schema, bits, scalar);
    return Generator.from(
        environment -> {
          int budget =
              (int)
                  Math.min(
                      Integer.MAX_VALUE,
                      Math.max(minimumBudget, 4L * environment.getSizeHint() + 1));
          return environment.generate(builder.generate(type, budget));
        });
  }

  /** A rejected predicate is retried; an evaluation error is delivered to the property. */
  public record Checked(Value value, RuntimeException error) {
    public Value requireValue() {
      if (error != null) throw error;
      return value;
    }
  }

  public static Generator<Checked> checkedGenerator(
      LawSpecSchema schema,
      Named type,
      int bits,
      int minimumBudget,
      Map<String, Object> symbols,
      List<Value> witnesses,
      Function<String, Generator<Value>> scalar) {
    return checkedGenerator(schema, type, bits, minimumBudget, 100, symbols, witnesses, scalar);
  }

  public static Generator<Checked> checkedGenerator(
      LawSpecSchema schema,
      Named type,
      int bits,
      int minimumBudget,
      int maxAttempts,
      Map<String, Object> symbols,
      List<Value> witnesses,
      Function<String, Generator<Value>> scalar) {
    return checkedGenerator(
        schema, type, bits, minimumBudget, maxAttempts, symbols, witnesses, scalar, Map.of());
  }

  public static Generator<Checked> checkedGenerator(
      LawSpecSchema schema,
      Named type,
      int bits,
      int minimumBudget,
      int maxAttempts,
      Map<String, Object> symbols,
      List<Value> witnesses,
      Function<String, Generator<Value>> scalar,
      Map<String, NativeFactory> factories) {
    if (maxAttempts < 1) throw new IllegalArgumentException("maxAttempts must be positive");
    var builder = new Builder(schema, bits, scalar, symbols, maxAttempts, factories);
    for (var witness : witnesses) {
      // Invalid witnesses indicate a compiler/caller error, not an empty domain.
      builder.addWitness(type, schema.validate(type, witness, bits, symbols));
    }
    return Generator.from(
        environment -> {
          try {
            int budget =
                (int)
                    Math.min(
                        Integer.MAX_VALUE,
                        Math.max(minimumBudget, 4L * environment.getSizeHint() + 1));
            var candidate =
                builder
                    .generate(type, budget)
                    .map(
                        value -> {
                          try {
                            var result = schema.check(type, value, bits, symbols);
                            if (result instanceof LawSpecSchema.Accepted accepted)
                              return new Checked(accepted.value(), null);
                            return new Checked(null, null);
                          } catch (RuntimeException error) {
                            return new Checked(null, error);
                          }
                        });
            // JetCheck bounds rejection at 100 attempts and discards invalid replays
            // while shrinking. Errors remain values so properties report them.
            return environment.generate(
                boundedFilter(
                    candidate,
                    checked -> checked.value() != null || checked.error() != null,
                    maxAttempts));
          } catch (NativeFailure error) {
            // Do not catch JetCheck's internal replay-control exceptions.
            return new Checked(null, error);
          }
        });
  }

  private static <T> Generator<T> boundedFilter(
      Generator<T> source, Predicate<T> predicate, int maxAttempts) {
    // JetCheck itself caps suchThat at 100 attempts. A smaller LawSpec budget
    // stops before drawing an additional candidate. This counter is recreated
    // during replay, so a rejected shrink is still discarded by native suchThat.
    if (maxAttempts >= 100) return source.suchThat(predicate);
    return Generator.from(
        environment -> {
          int[] attempts = {0};
          Generator<T> limited =
              Generator.from(
                  candidate -> {
                    if (attempts[0]++ >= maxAttempts)
                      throw new IllegalArgumentException(
                          "constructor generation exhausted " + maxAttempts + " attempts");
                    return candidate.generate(source);
                  });
          return environment.generate(limited.suchThat(predicate));
        });
  }

  private static int nodes(Value value) {
    if (value.data() instanceof Data data)
      return 1 + data.fields().stream().mapToInt(LawSpecDataStrategies::nodes).sum();
    if (value.data() instanceof Presence presence)
      return 1 + (presence.present() ? nodes(presence.value()) : 0);
    if (value.type().startsWith("List "))
      return 1 + ((List<?>) value.data()).stream().mapToInt(item -> nodes((Value) item)).sum();
    return 1;
  }

  private record Request(Named type, int budget) {}

  private static final class Builder {
    private final LawSpecSchema schema;
    private final int bits;
    private final Function<String, Generator<Value>> scalar;
    private final boolean unchecked;
    private final int maxAttempts;
    private final Map<String, Object> symbols;
    private final Map<Named, List<Value>> witnesses = new HashMap<>();
    private final Map<Request, Boolean> inhabited = new HashMap<>();
    private final Map<Request, Generator<Value>> generators = new HashMap<>();
    private final Map<String, NativeFactory> factories;

    Builder(LawSpecSchema schema, int bits, Function<String, Generator<Value>> scalar) {
      this(schema, bits, scalar, null, 100);
    }

    Builder(
        LawSpecSchema schema,
        int bits,
        Function<String, Generator<Value>> scalar,
        Map<String, Object> symbols,
        int maxAttempts) {
      this(schema, bits, scalar, symbols, maxAttempts, Map.of());
    }

    Builder(
        LawSpecSchema schema,
        int bits,
        Function<String, Generator<Value>> scalar,
        Map<String, Object> symbols,
        int maxAttempts,
        Map<String, NativeFactory> factories) {
      boolean unchecked = symbols != null;
      if (!unchecked && schema.hasContracts())
        throw new IllegalArgumentException("constructor contracts require checked generation");
      this.unchecked = unchecked;
      this.maxAttempts = maxAttempts;
      this.symbols = symbols;
      this.schema = schema;
      this.bits = bits;
      this.scalar = scalar;
      this.factories = Map.copyOf(factories);
    }

    private void addWitness(Named type, Value value) {
      witnesses.computeIfAbsent(type, ignored -> new ArrayList<>()).add(value);
      if (schema.isScalar(type)) return;
      if (type.name().equals("List")) {
        for (var item : (List<?>) value.data())
          addWitness((Named) type.arguments().get(0), (Value) item);
      } else if (type.name().equals("Nullable") || type.name().equals("Optional")) {
        var presence = (Presence) value.data();
        if (presence.present()) addWitness((Named) type.arguments().get(0), presence.value());
      } else {
        var data = (Data) value.data();
        var fields = schema.fields(type, data.tag());
        for (int i = 0; i < fields.size(); i++)
          addWitness((Named) fields.get(i).type(), data.fields().get(i));
      }
    }

    private boolean canGenerate(Named type, int budget) {
      if (budget < 1) return false;
      if (factories.containsKey(type.name())) return true;
      var request = new Request(type, budget);
      if (inhabited.containsKey(request)) return inhabited.get(request);
      boolean result;
      if (schema.isScalar(type)
          || type.name().equals("List")
          || type.name().equals("Nullable")
          || type.name().equals("Optional")) {
        result = true;
      } else {
        result =
            schema.constructors(type).stream()
                .anyMatch(tag -> allocation(schema.fields(type, tag), budget - 1) != null);
      }
      inhabited.put(request, result);
      return result;
    }

    private List<Integer> allocation(List<LawSpecSchema.Field> fields, int budget) {
      var costs = new ArrayList<Integer>();
      int remaining = budget;
      for (var field : fields) {
        int minimum = 1;
        while (minimum <= remaining && !canGenerate((Named) field.type(), minimum)) minimum++;
        if (minimum > remaining) return null;
        costs.add(minimum);
        remaining -= minimum;
      }
      for (int i = 0; i < costs.size(); i++) {
        costs.set(
            i, costs.get(i) + remaining / costs.size() + (i < remaining % costs.size() ? 1 : 0));
      }
      return costs;
    }

    Generator<Value> generate(Named type, int budget) {
      if (!canGenerate(type, budget)) {
        throw new IllegalArgumentException(
            "no inhabitant of "
                + LawSpecSchema.key(type)
                + " within structural node budget "
                + budget);
      }
      var request = new Request(type, budget);
      if (generators.containsKey(request)) return generators.get(request);
      if (factories.containsKey(type.name())) {
        var arguments = new ArrayList<Generator<Value>>();
        for (var argument : type.arguments()) {
          int remaining = Math.max(1, budget - 1);
          // An uninhabited parameter need not be stored by the native type.
          // JetCheck bounds rejection if its factory actually draws this child.
          arguments.add(
              canGenerate((Named) argument, remaining)
                  ? generate((Named) argument, remaining)
                  : Generator.constant(new Value("Unit", null)).suchThat(ignored -> false));
        }
        var source = factories.get(type.name()).create(schema, type, bits, symbols, arguments);
        if (source == null) {
          throw new IllegalArgumentException("native generator " + type.name() + " returned null");
        }
        var nativeGenerator =
            source.map(
                value -> {
                  try {
                    return schema.validate(type, value, bits, symbols);
                  } catch (RuntimeException error) {
                    throw new NativeFailure(type, error);
                  }
                });
        generators.put(request, nativeGenerator);
        return nativeGenerator;
      }
      Generator<Value> generator;
      if (schema.isScalar(type)) {
        generator = scalar.apply(type.name()).map(value -> schema.validate(type, value, bits));
      } else if (type.name().equals("List")) {
        var element = (Named) type.arguments().get(0);
        int maxLength = budget - 1;
        while (maxLength > 0 && !canGenerate(element, (budget - 1) / maxLength)) maxLength--;
        generator =
            Generator.integers(0, maxLength)
                .flatMap(
                    length ->
                        length == 0
                            ? Generator.constant(new Value(LawSpecSchema.key(type), List.of()))
                            : Generator.listsOf(
                                    IntDistribution.uniform(length, length),
                                    generate(element, (budget - 1) / length))
                                .map(
                                    values ->
                                        new Value(LawSpecSchema.key(type), List.copyOf(values))));
      } else if (type.name().equals("Nullable") || type.name().equals("Optional")) {
        var element = (Named) type.arguments().get(0);
        var absent =
            Generator.constant(new Value(LawSpecSchema.key(type), new Presence(false, null)));
        generator =
            canGenerate(element, budget - 1)
                ? Generator.anyOf(
                    absent,
                    generate(element, budget - 1)
                        .map(
                            value -> new Value(LawSpecSchema.key(type), new Presence(true, value))))
                : absent;
      } else {
        var variants = new ArrayList<Generator<Value>>();
        for (var tag : schema.constructors(type)) {
          var fields = schema.fields(type, tag);
          var budgets = allocation(fields, budget - 1);
          if (budgets == null) continue;
          var children = new ArrayList<Generator<Value>>();
          for (int i = 0; i < fields.size(); i++) {
            children.add(generate((Named) fields.get(i).type(), budgets.get(i)));
          }
          variants.add(
              Generator.from(
                  environment -> {
                    var values = new ArrayList<Value>();
                    for (var child : children) values.add(environment.generate(child));
                    return unchecked
                        ? new Value(LawSpecSchema.key(type), new Data(tag, List.copyOf(values)))
                        : schema.construct(type, tag, values, bits);
                  }));
        }
        generator = Generator.anyOf(variants);
      }
      if (witnesses.containsKey(type)) {
        var seeds = witnesses.get(type).stream().filter(value -> nodes(value) <= budget).toList();
        if (!seeds.isEmpty()) generator = Generator.anyOf(generator, Generator.sampledFrom(seeds));
      }
      if (unchecked && !schema.isScalar(type)) {
        generator =
            boundedFilter(
                generator,
                value -> {
                  try {
                    return schema.check(type, value, bits, symbols)
                        instanceof LawSpecSchema.Accepted;
                  } catch (RuntimeException error) {
                    // Keep evaluation errors for the outer checked result to report.
                    return true;
                  }
                },
                maxAttempts);
      }
      generators.put(request, generator);
      return generator;
    }
  }
}
