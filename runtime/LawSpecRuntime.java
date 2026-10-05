package lawspec.runtime;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Random;
import java.util.function.BiFunction;
import java.util.function.Function;
import java.util.function.Supplier;

/** Portable scalar and collection values, independent of test frameworks. */
public final class LawSpecRuntime {
  private LawSpecRuntime() {}

  public record Value(String type, Object data) {
    @Override
    public String toString() {
      return "Value[type="
          + type
          + ", data="
          + (data instanceof int[] units ? Arrays.toString(units) : String.valueOf(data))
          + "]";
    }
  }

  public record Complex(double real, double imaginary) {}

  /**
   * A handle's logical data: the native object an adapter made, passed along unopened. Two handles
   * are equal only when they hold the same object; they have no portable order.
   */
  public static final class Handle {
    private final Object target;

    public Handle(Object target) {
      this.target = Objects.requireNonNull(target, "a handle cannot be null");
    }

    public Object target() {
      return target;
    }

    @Override
    public boolean equals(Object other) {
      return other instanceof Handle handle && handle.target == target;
    }

    @Override
    public int hashCode() {
      return System.identityHashCode(target);
    }

    @Override
    public String toString() {
      return "Handle[" + target.getClass().getName() + "]";
    }
  }

  /** A handle's logical value, carrying its native object. */
  public static Value handle(String type, Object target) {
    return new Value(type, new Handle(target));
  }

  /** The native object a handle's logical value carries. */
  public static Object handleTarget(Value value) {
    if (!(value.data() instanceof Handle handle))
      throw new IllegalArgumentException("handle required: " + value.type());
    return handle.target();
  }

  private static final Map<Object, Integer> HANDLE_LABELS = new java.util.IdentityHashMap<>();
  private static final Map<String, Integer> HANDLE_COUNTS = new java.util.HashMap<>();

  /** A handle's stable label, such as Jobs#1: its type's name, numbered by first appearance. */
  private static String handleLabel(String type, Object target) {
    int cut = type.lastIndexOf("::");
    String name = cut < 0 ? type : type.substring(cut + 2);
    synchronized (HANDLE_LABELS) {
      Integer number = HANDLE_LABELS.get(target);
      if (number == null) {
        number = HANDLE_COUNTS.merge(name, 1, Integer::sum);
        HANDLE_LABELS.put(target, number);
      }
      return name + "#" + number;
    }
  }

  public record SymbolValue(String description) {}

  public record Presence(boolean present, Value value) {}

  public sealed interface Maybe<T> permits Nothing, Just {}

  public record Nothing<T>() implements Maybe<T> {}

  public record Just<T>(T value) implements Maybe<T> {}

  public sealed interface Either<L, R> permits Left, Right {}

  public record Left<L, R>(L value) implements Either<L, R> {}

  public record Right<L, R>(R value) implements Either<L, R> {}

  public record Data(String tag, List<Value> fields) {
    public Data {
      fields = List.copyOf(fields);
    }
  }

  public record Ratio(BigInteger n, BigInteger d) {
    public Ratio {
      if (d.signum() == 0) throw new ArithmeticException("exact division by zero");
      if (d.signum() < 0) {
        n = n.negate();
        d = d.negate();
      }
      var gcd = n.gcd(d);
      n = n.divide(gcd);
      d = d.divide(gcd);
    }
  }

  private static final java.util.regex.Pattern INTEGER_TYPE =
      java.util.regex.Pattern.compile("(U?Int(8|16|32|64|Size)|UIntPtr|BigU?Int|Integer)");

  public static boolean integerType(String t) {
    return INTEGER_TYPE.matcher(t).matches();
  }

  public static boolean exactType(String t) {
    return integerType(t) || t.equals("Decimal") || t.equals("Rational");
  }

  public static Value integer(String t, String n) {
    return new Value(t, new BigInteger(n));
  }

  public static Value decimal(String c, String e) {
    return new Value(
        "Decimal", new BigDecimal(new BigInteger(c), Math.negateExact(Integer.parseInt(e))));
  }

  public static Value rational(String n, String d) {
    return new Value("Rational", new Ratio(new BigInteger(n), new BigInteger(d)));
  }

  public static Value bool(boolean b) {
    return new Value("Bool", b);
  }

  public static Value floating(String t, String bits) {
    return new Value(
        t,
        t.equals("Float32")
            ? (double) Float.intBitsToFloat(Integer.parseUnsignedInt(bits, 16))
            : Double.longBitsToDouble(Long.parseUnsignedLong(bits, 16)));
  }

  public static Value complex(String t, Value r, Value i) {
    return new Value(t, new Complex((double) r.data, (double) i.data));
  }

  public static Value sequence(String t, int[] units) {
    return new Value(t, Arrays.stream(units).boxed().toList());
  }

  public static Value character(String t, int c) {
    return new Value(t, c);
  }

  public static Value absent(String t) {
    return new Value(t, null);
  }

  public static Value present(String t, Value v) {
    return new Value(t, new Presence(v != null, v));
  }

  public static Value symbol(String id, String description, Map<String, Object> symbols) {
    return new Value("Symbol", symbols.computeIfAbsent(id, k -> new SymbolValue(description)));
  }

  public static Value list(String type, List<Value> values) {
    if (!type.startsWith("List ")) {
      throw new IllegalArgumentException("List type required");
    }
    return new Value(type, List.copyOf(values));
  }

  private static List<Value> listElements(Value value) {
    if (value == null
        || !value.type.startsWith("List ")
        || !(value.data instanceof List<?> values)) {
      throw new IllegalArgumentException("List value required");
    }
    var result = new ArrayList<Value>(values.size());
    for (Object element : values) {
      if (!(element instanceof Value field)) {
        throw new IllegalArgumentException("invalid List element representation");
      }
      result.add(field);
    }
    return result;
  }

  public static Value construct(String type, String tag, Value[] fields) {
    if (sumType(type)) {
      if (sumFields(type, tag).size() != fields.length) {
        throw new IllegalArgumentException("invalid constructor arity: " + tag);
      }
      return new Value(type, new Data(tag, Arrays.asList(fields)));
    }
    if (tag.equals("List::Nil") && fields.length == 0) {
      return list(type, List.of());
    }
    if (tag.equals("List::Cons") && fields.length == 2) {
      var values = new ArrayList<Value>();
      values.add(fields[0]);
      values.addAll(listElements(fields[1]));
      return list(type, values);
    }
    throw new IllegalArgumentException("invalid constructor or arity: " + tag);
  }

  private static boolean sumType(String type) {
    return type.startsWith("Maybe ") || type.startsWith("Either ");
  }

  private static List<String> eitherArguments(String type) {
    if (!type.startsWith("Either ")) {
      throw new IllegalArgumentException("Either type required");
    }
    var arguments = new ArrayList<String>();
    int cursor = 7;
    while (cursor < type.length()) {
      if (type.charAt(cursor) != '(') {
        throw new IllegalArgumentException("invalid Either type: " + type);
      }
      int start = ++cursor;
      int depth = 1;
      while (cursor < type.length() && depth > 0) {
        char unit = type.charAt(cursor++);
        if (unit == '(') depth++;
        if (unit == ')') depth--;
      }
      if (depth != 0 || cursor == start + 1) {
        throw new IllegalArgumentException("invalid Either type: " + type);
      }
      arguments.add(type.substring(start, cursor - 1));
      if (cursor < type.length() && type.charAt(cursor++) != ' ') {
        throw new IllegalArgumentException("invalid Either type: " + type);
      }
    }
    if (arguments.size() != 2) {
      throw new IllegalArgumentException("Either requires two type arguments");
    }
    return arguments;
  }

  private static List<String> sumFields(String type, String tag) {
    if (type.startsWith("Maybe ")) {
      if (tag.equals("Maybe::Nothing")) return List.of();
      if (tag.equals("Maybe::Just")) return List.of(type.substring(6));
    } else if (type.startsWith("Either ")) {
      var arguments = eitherArguments(type);
      if (tag.equals("Either::Left")) return List.of(arguments.get(0));
      if (tag.equals("Either::Right")) return List.of(arguments.get(1));
    }
    throw new IllegalArgumentException("invalid constructor " + tag + " for " + type);
  }

  private static Data dataValue(Value value) {
    if (value == null
        || !(value.data instanceof Data data)
        || sumFields(value.type, data.tag).size() != data.fields.size()) {
      throw new IllegalArgumentException("invalid sum value representation");
    }
    return data;
  }

  public static <T> Maybe<T> maybeToNative(
      String type, Value value, int bits, Function<Value, T> element) {
    if (!type.startsWith("Maybe ")) throw new IllegalArgumentException("Maybe type required");
    var data = dataValue(convert(type, value, bits));
    return data.tag.equals("Maybe::Nothing")
        ? new Nothing<>()
        : new Just<>(element.apply(data.fields.getFirst()));
  }

  public static <L, R> Either<L, R> eitherToNative(
      String type, Value value, int bits, Function<Value, L> left, Function<Value, R> right) {
    if (!type.startsWith("Either ")) throw new IllegalArgumentException("Either type required");
    var data = dataValue(convert(type, value, bits));
    return data.tag.equals("Either::Left")
        ? new Left<>(left.apply(data.fields.getFirst()))
        : new Right<>(right.apply(data.fields.getFirst()));
  }

  public static Value matchMaybe(
      Value value, Supplier<Value> nothing, Function<Value, Value> just) {
    var data = dataValue(value);
    return switch (data.tag) {
      case "Maybe::Nothing" -> nothing.get();
      case "Maybe::Just" -> just.apply(data.fields.getFirst());
      default -> throw new IllegalArgumentException("Maybe value required");
    };
  }

  public static Value matchEither(
      Value value, Function<Value, Value> left, Function<Value, Value> right) {
    var data = dataValue(value);
    return switch (data.tag) {
      case "Either::Left" -> left.apply(data.fields.getFirst());
      case "Either::Right" -> right.apply(data.fields.getFirst());
      default -> throw new IllegalArgumentException("Either value required");
    };
  }

  public static <T> List<T> listToNative(
      String type, Value value, int bits, Function<Value, T> element) {
    var values = listElements(convert(type, value, bits));
    var result = new ArrayList<T>(values.size());
    for (Value field : values) {
      result.add(element.apply(field));
    }
    return result;
  }

  public static Value refineElements(
      Value value, Function<Value, Value> prepare, Function<Value, Value> predicate) {
    var accepted = new ArrayList<Value>();
    for (Value item : listElements(value)) {
      Value prepared = prepare.apply(item);
      if (truth(predicate.apply(prepared))) accepted.add(prepared);
    }
    return list(value.type, accepted);
  }

  public static Value allElements(Value value, Function<Value, Value> predicate) {
    var values = listElements(value);
    for (int index = 0; index < values.size(); index++) {
      try {
        if (!truth(predicate.apply(values.get(index)))) return bool(false);
      } catch (RuntimeException error) {
        throw new IllegalArgumentException(
            "List element " + index + ": " + error.getMessage(), error);
      }
    }
    return bool(true);
  }

  public static Value matchList(
      Value value, Supplier<Value> nil, BiFunction<Value, Value, Value> cons) {
    var values = listElements(value);
    if (values.isEmpty()) return nil.get();
    return cons.apply(values.getFirst(), list(value.type, values.subList(1, values.size())));
  }

  private static Ratio ratio(Value v) {
    if (integerType(v.type)) return new Ratio((BigInteger) v.data, BigInteger.ONE);
    if (v.data instanceof Ratio r) return r;
    if (v.data instanceof BigDecimal d) {
      int s = d.scale();
      return new Ratio(
          s < 0 ? d.unscaledValue().multiply(BigInteger.TEN.pow(-s)) : d.unscaledValue(),
          s < 0 ? BigInteger.ONE : BigInteger.TEN.pow(s));
    }
    throw new IllegalArgumentException("exact numeric value required");
  }

  private static double real(Value v) {
    if (v.data instanceof Double d) return d;
    Ratio r = ratio(v);
    return new BigDecimal(r.n)
        .divide(new BigDecimal(r.d), new java.math.MathContext(400, RoundingMode.HALF_EVEN))
        .doubleValue();
  }

  private static double precision(String t, double d) {
    return t.equals("Float32") || t.equals("Complex64") ? (double) (float) d : d;
  }

  public static Value convert(String t, Value v, int bits) {
    if (sumType(t)) {
      var data = dataValue(v);
      var types = sumFields(t, data.tag);
      var fields = new ArrayList<Value>();
      for (int i = 0; i < types.size(); i++) {
        fields.add(convert(types.get(i), data.fields.get(i), bits));
      }
      return new Value(t, new Data(data.tag, fields));
    }
    if (t.startsWith("List ")) {
      var result = new ArrayList<Value>();
      for (Value field : listElements(v)) {
        result.add(convert(t.substring(5), field, bits));
      }
      return list(t, result);
    }
    if (t.startsWith("Nullable ") || t.startsWith("Optional ")) {
      int i = t.indexOf(' ');
      String k = t.substring(0, i);
      if (v.type.equals(k.equals("Nullable") ? "Null" : "Undefined"))
        return new Value(t, new Presence(false, null));
      if (v.data instanceof Presence p)
        return new Value(
            t,
            new Presence(p.present, p.present ? convert(t.substring(i + 1), p.value, bits) : null));
      throw new IllegalArgumentException("tagged presence required");
    }
    if (integerType(t)) {
      Ratio r =
          v.data instanceof Double d ? ratio(new Value("Decimal", new BigDecimal(d))) : ratio(v);
      if (!r.d.equals(BigInteger.ONE))
        throw new ArithmeticException("fractional conversion to " + t);
      if (!t.equals("BigInt") && !t.equals("Integer")) {
        if (t.startsWith("U") || t.equals("BigUInt")) {
          if (r.n.signum() < 0) throw new ArithmeticException("integer outside " + t + " range");
        }
        if (!t.equals("BigUInt")) {
          int w =
              t.endsWith("Size") || t.equals("UIntPtr")
                  ? bits
                  : Integer.parseInt(t.replaceAll("\\D", ""));
          boolean signed = t.startsWith("Int");
          BigInteger hi = BigInteger.ONE.shiftLeft(signed ? w - 1 : w).subtract(BigInteger.ONE),
              lo = signed ? BigInteger.ONE.shiftLeft(w - 1).negate() : BigInteger.ZERO;
          if (r.n.compareTo(lo) < 0 || r.n.compareTo(hi) > 0)
            throw new ArithmeticException("integer outside " + t + " range");
        }
      }
      return new Value(t, r.n);
    }
    if (t.equals("Rational") || t.equals("Decimal")) {
      Ratio r =
          v.data instanceof Double d ? ratio(new Value("Decimal", new BigDecimal(d))) : ratio(v);
      return new Value(
          t, t.equals("Rational") ? r : new BigDecimal(r.n).divide(new BigDecimal(r.d)));
    }
    if (t.startsWith("Float"))
      return new Value(
          t, exactType(v.type) ? exactFloat(ratio(v), t.equals("Float32")) : precision(t, real(v)));
    if (t.startsWith("Complex")) {
      Complex c =
          v.data instanceof Complex z
              ? z
              : new Complex(
                  (double) convert(t.equals("Complex64") ? "Float32" : "Float64", v, bits).data, 0);
      return new Value(t, new Complex(precision(t, c.real), precision(t, c.imaginary)));
    }
    if (!t.equals(v.type))
      throw new IllegalArgumentException("cannot convert " + v.type + " to " + t);
    return validate(t, v, bits);
  }

  private static boolean validUnit(String t, int c) {
    return c >= 0
        && c
            <= (t.equals("Bytes")
                ? 255
                : t.equals("Utf16Text") || t.equals("CodeUnit16") ? 65535 : 1114111)
        && (!(t.equals("Char") || t.equals("Text")) || c < 55296 || c > 57343);
  }

  public static Value validate(String t, Value v, int bits) {
    if (v == null && t.equals("Unit")) return absent("Unit");
    if (v == null || !v.type.equals(t))
      throw new IllegalArgumentException("invalid " + t + " representation");
    if (sumType(t)) {
      var data = dataValue(v);
      var types = sumFields(t, data.tag);
      var fields = new ArrayList<Value>();
      for (int i = 0; i < types.size(); i++) {
        fields.add(validate(types.get(i), data.fields.get(i), bits));
      }
      return new Value(t, new Data(data.tag, fields));
    }
    if (t.startsWith("List ")) {
      var result = new ArrayList<Value>();
      for (Value field : listElements(v)) {
        result.add(validate(t.substring(5), field, bits));
      }
      return list(t, result);
    }
    if (integerType(t)) return convert(t, v, bits);
    Object data = v.data;
    boolean valid;
    if (t.startsWith("Nullable ") || t.startsWith("Optional ")) {
      valid = data instanceof Presence;
      if (valid) {
        Presence p = (Presence) data;
        if (p.present) validate(t.substring(t.indexOf(' ') + 1), p.value, bits);
      }
    } else if (List.of("Text", "CodePointText", "Utf16Text", "Bytes").contains(t)) {
      valid = data instanceof List<?>;
      if (valid)
        for (Object x : (List<?>) data)
          if (!(x instanceof Integer c) || !validUnit(t, c)) valid = false;
    } else if (List.of("Char", "CodePoint", "CodeUnit16").contains(t))
      valid = data instanceof Integer c && validUnit(t, c);
    else if (t.equals("Bool")) valid = data instanceof Boolean;
    else if (t.equals("Decimal")) valid = data instanceof BigDecimal;
    else if (t.equals("Rational")) valid = data instanceof Ratio;
    else if (t.startsWith("Float"))
      valid =
          data instanceof Double d
              && (t.equals("Float64") || Double.isNaN(d) || (double) (float) d.doubleValue() == d);
    else if (t.startsWith("Complex")) {
      valid = data instanceof Complex;
      if (valid) {
        Complex c = (Complex) data;
        String component = t.equals("Complex64") ? "Float32" : "Float64";
        validate(component, new Value(component, c.real), bits);
        validate(component, new Value(component, c.imaginary), bits);
      }
    } else if (t.equals("Symbol")) valid = data instanceof SymbolValue;
    else valid = List.of("Unit", "Null", "Undefined").contains(t) && data == null;
    if (!valid) throw new IllegalArgumentException("invalid " + t + " representation");
    if (data instanceof List<?> xs) return new Value(t, List.copyOf(xs));
    if (data instanceof Presence p && p.present)
      return new Value(
          t, new Presence(true, validate(t.substring(t.indexOf(' ') + 1), p.value, bits)));
    return v;
  }

  private static String promote(String a, String b, String op) {
    if (exactType(a) != exactType(b))
      throw new IllegalArgumentException("exact/inexact mixing requires explicit conversion");
    if (exactType(a))
      return op.equals("/") || a.equals("Rational") || b.equals("Rational")
          ? "Rational"
          : a.equals("Decimal") || b.equals("Decimal") ? "Decimal" : "Integer";
    if (a.startsWith("Complex") || b.startsWith("Complex"))
      return a.equals("Float64")
              || b.equals("Float64")
              || a.equals("Complex128")
              || b.equals("Complex128")
          ? "Complex128"
          : "Complex64";
    return a.equals("Float64") || b.equals("Float64") ? "Float64" : "Float32";
  }

  private static boolean compare(String op, int c) {
    return switch (op) {
      case "==" -> c == 0;
      case "!=" -> c != 0;
      case "<" -> c < 0;
      case "<=" -> c <= 0;
      case ">" -> c > 0;
      case ">=" -> c >= 0;
      default -> throw new IllegalArgumentException(op);
    };
  }

  public static Value binary(String op, Value a, Value b) {
    if ((op.equals("==") || op.equals("!="))
        && !exactType(a.type)
        && !a.type.startsWith("Float")
        && !a.type.startsWith("Complex")) return bool(op.equals("==") == equal(a, b));
    String t = promote(a.type, b.type, op);
    if (exactType(a.type)) {
      Ratio x = ratio(a), y = ratio(b);
      BigInteger p = x.n.multiply(y.d), q = y.n.multiply(x.d), d = x.d.multiply(y.d);
      if (List.of("==", "!=", "<", "<=", ">", ">=").contains(op))
        return bool(compare(op, p.compareTo(q)));
      if (op.equals("pow")) {
        if (!x.d.equals(BigInteger.ONE) || !y.d.equals(BigInteger.ONE))
          throw new IllegalArgumentException("integer required");
        if (y.n.signum() < 0) throw new IllegalArgumentException("negative exponent");
        return new Value("Integer", x.n.pow(y.n.intValueExact()));
      }
      if (op.equals("quot") || op.equals("rem")) {
        if (!x.d.equals(BigInteger.ONE) || !y.d.equals(BigInteger.ONE))
          throw new IllegalArgumentException("integer required");
        return new Value("Integer", op.equals("quot") ? x.n.divide(y.n) : x.n.remainder(y.n));
      }
      Ratio r =
          switch (op) {
            case "+" -> new Ratio(p.add(q), d);
            case "-" -> new Ratio(p.subtract(q), d);
            case "*" -> new Ratio(x.n.multiply(y.n), d);
            case "/" -> new Ratio(x.n.multiply(y.d), x.d.multiply(y.n));
            default -> throw new IllegalArgumentException(op);
          };
      return convert(t, new Value("Rational", r), 64);
    }
    if (t.startsWith("Complex")) {
      Complex x = (Complex) convert(t, a, 64).data, y = (Complex) convert(t, b, 64).data;
      double re, im;
      if (op.equals("==") || op.equals("!="))
        return bool(op.equals("==") == (x.real == y.real && x.imaginary == y.imaginary));
      if (op.equals("+")) {
        re = x.real + y.real;
        im = x.imaginary + y.imaginary;
      } else if (op.equals("-")) {
        re = x.real - y.real;
        im = x.imaginary - y.imaginary;
      } else if (op.equals("*")) {
        re = precision(t, x.real * y.real) - precision(t, x.imaginary * y.imaginary);
        im = precision(t, x.real * y.imaginary) + precision(t, x.imaginary * y.real);
      } else {
        double d =
            precision(t, precision(t, y.real * y.real) + precision(t, y.imaginary * y.imaginary));
        re =
            precision(t, precision(t, x.real * y.real) + precision(t, x.imaginary * y.imaginary))
                / d;
        im =
            precision(t, precision(t, x.imaginary * y.real) - precision(t, x.real * y.imaginary))
                / d;
      }
      return new Value(t, new Complex(precision(t, re), precision(t, im)));
    }
    double x = real(a), y = real(b);
    if (List.of("==", "!=", "<", "<=", ">", ">=").contains(op))
      return bool(
          switch (op) {
            case "==" -> x == y;
            case "!=" -> x != y;
            case "<" -> x < y;
            case "<=" -> x <= y;
            case ">" -> x > y;
            default -> x >= y;
          });
    return new Value(
        t,
        precision(
            t,
            switch (op) {
              case "+" -> x + y;
              case "-" -> x - y;
              case "*" -> x * y;
              case "/" -> x / y;
              default -> throw new IllegalArgumentException(op);
            }));
  }

  public static boolean equal(Value a, Value b) {
    if (a.data instanceof Handle || b.data instanceof Handle) return Objects.equals(a.data, b.data);
    if (sumType(a.type) || sumType(b.type)) {
      if (!sumType(a.type) || !sumType(b.type)) return false;
      var left = dataValue(a);
      var right = dataValue(b);
      if (!left.tag.equals(right.tag) || left.fields.size() != right.fields.size()) return false;
      for (int i = 0; i < left.fields.size(); i++) {
        if (!equal(left.fields.get(i), right.fields.get(i))) return false;
      }
      return true;
    }
    if (a.type.startsWith("List ") && b.type.startsWith("List ")) {
      var left = listElements(a);
      var right = listElements(b);
      if (left.size() != right.size()) return false;
      for (int index = 0; index < left.size(); index++) {
        if (!equal(left.get(index), right.get(index))) return false;
      }
      return true;
    }
    if ((a.type.startsWith("Float") || a.type.startsWith("Complex"))
        && (b.type.startsWith("Float") || b.type.startsWith("Complex")))
      return truth(binary("==", a, b));
    if (exactType(a.type) && exactType(b.type)) return ratio(a).equals(ratio(b));
    if (a.data instanceof Double x && b.data instanceof Double y)
      return x.doubleValue() == y.doubleValue();
    if (a.data instanceof Complex x && b.data instanceof Complex y)
      return x.real == y.real && x.imaginary == y.imaginary;
    if (a.data instanceof Presence x && b.data instanceof Presence y)
      return a.type.equals(b.type)
          && x.present == y.present
          && (!x.present || equal(x.value, y.value));
    if (a.type.equals("Symbol")) return a.data == b.data;
    return a.type.equals(b.type) && Objects.equals(a.data, b.data);
  }

  public static boolean truth(Value v) {
    return (boolean) validate("Bool", v, 64).data;
  }

  private static final String ORDERING = "lawspec.collections::type::Ordering";

  /**
   * The portable total order: -1, 0 or 1. Exact numbers by value, sequences by unit, false before
   * true, absence before presence, lists element by element, Nothing before Just, and other data
   * by constructor identity, then fields left to right.
   */
  public static int compareValues(Value a, Value b) {
    if (a.data instanceof Handle x && b.data instanceof Handle y) {
      if (x.target == y.target) return 0;
      throw new IllegalArgumentException("handles have no portable order: " + a.type);
    }
    if (a.data == null && b.data == null) return 0;
    if (a.data instanceof Boolean x && b.data instanceof Boolean y) return Boolean.compare(x, y);
    if (exactType(a.type) && exactType(b.type)) {
      Ratio x = ratio(a), y = ratio(b);
      return Integer.signum(x.n().multiply(y.d()).compareTo(y.n().multiply(x.d())));
    }
    if (a.data instanceof Integer x && b.data instanceof Integer y) return Integer.signum(Integer.compare(x, y));
    if (a.data instanceof Presence x && b.data instanceof Presence y) {
      if (x.present() != y.present()) return x.present() ? 1 : -1;
      return x.present() ? compareValues(x.value(), y.value()) : 0;
    }
    if (a.data instanceof List<?> x && b.data instanceof List<?> y) return compareItems(x, y);
    if (a.data instanceof Data x && b.data instanceof Data y) {
      if (!x.tag().equals(y.tag())) {
        if (x.tag().equals("Maybe::Nothing") && y.tag().equals("Maybe::Just")) return -1;
        if (x.tag().equals("Maybe::Just") && y.tag().equals("Maybe::Nothing")) return 1;
        return Integer.signum(x.tag().compareTo(y.tag()));
      }
      return compareItems(x.fields(), y.fields());
    }
    throw new IllegalArgumentException("values have no portable order: " + a.type);
  }

  private static int compareItems(List<?> x, List<?> y) {
    for (int i = 0; i < Math.min(x.size(), y.size()); i++) {
      int order =
          x.get(i) instanceof Value u
              ? compareValues(u, (Value) y.get(i))
              : Integer.signum(Integer.compare((Integer) x.get(i), (Integer) y.get(i)));
      if (order != 0) return order;
    }
    return Integer.signum(Integer.compare(x.size(), y.size()));
  }

  public static Value helper(String n, Value[] args, int bits) {
    if (n.equals("checked")) return bool(true);
    if (n.equals("select")) return truth(args[0]) ? args[1] : args[2];
    if (n.equals("compare")) {
      var tag = new String[] {"Less", "Equal", "Greater"}[compareValues(args[0], args[1]) + 1];
      return new Value(ORDERING, new Data(ORDERING + "::" + tag, List.of()));
    }
    if (n.equals("length"))
      return integer("Integer", Integer.toString(((List<?>) args[0].data).size()));
    if (n.equals("isPresent")) return bool(((Presence) args[0].data).present);
    if (n.equals("presentValue")) {
      Presence p = (Presence) args[0].data;
      if (!p.present) throw new IllegalArgumentException("absent presence value");
      return p.value;
    }

    Value x = args[0];
    if (n.equals("real") || n.equals("imag")) {
      Complex c = (Complex) x.data;
      return new Value(
          x.type.equals("Complex64") ? "Float32" : "Float64",
          n.equals("real") ? c.real : c.imaginary);
    }
    if (n.equals("quot") || n.equals("rem") || n.equals("pow")) return binary(n, x, args[1]);
    if (n.equals("negate")) {
      if (exactType(x.type)) return binary("-", integer("BigInt", "0"), x);
      if (x.data instanceof Complex c) return new Value(x.type, new Complex(-c.real, -c.imaginary));
      return new Value(x.type, -real(x));
    }
    if (n.equals("isNaN")) return bool(Double.isNaN(real(x)));
    if (n.equals("isInfinite")) return bool(Double.isInfinite(real(x)));
    if (n.equals("isFinite")) return bool(Double.isFinite(real(x)));
    if (n.equals("isNegativeZero"))
      return bool(Double.doubleToRawLongBits(real(x)) == Long.MIN_VALUE);
    if (n.equals("round")) {
      Ratio r = ratio(x);
      int scale = ((BigInteger) convert("Int32", args[1], bits).data).intValueExact();
      return new Value(
          "Decimal",
          new BigDecimal(r.n).divide(new BigDecimal(r.d), scale, RoundingMode.HALF_EVEN));
    }
    return convert(n, x, bits);
  }

  public static Value sample(String t, int seed, int bits) {
    Random random = new Random(seed);
    if (t.startsWith("Nullable ") || t.startsWith("Optional ")) {
      int i = t.indexOf(' ');
      return new Value(
          t,
          new Presence(random.nextBoolean(), sample(t.substring(i + 1), random.nextInt(), bits)));
    }
    if (integerType(t)) {
      if (t.equals("Integer") || t.equals("BigInt") || t.equals("BigUInt")) {
        BigInteger n = new BigInteger(256, random);
        return new Value(
            t,
            (t.equals("BigInt") || t.equals("Integer")) && random.nextBoolean() ? n.negate() : n);
      }
      int w =
          t.endsWith("Size") || t.equals("UIntPtr")
              ? bits
              : Integer.parseInt(t.replaceAll("\\D", ""));
      BigInteger n = new BigInteger(w, random);
      if (t.startsWith("Int") && n.testBit(w - 1)) n = n.subtract(BigInteger.ONE.shiftLeft(w));
      return new Value(t, n);
    }
    if (t.equals("Bool")) return bool(random.nextBoolean());
    if (t.equals("Decimal"))
      return new Value(t, new BigDecimal(new BigInteger(128, random), random.nextInt(41) - 20));
    if (t.equals("Rational"))
      return new Value(
          t,
          new Ratio(
              new BigInteger(128, random).subtract(BigInteger.ONE.shiftLeft(127)),
              new BigInteger(128, random).add(BigInteger.ONE)));
    if (t.startsWith("Float"))
      return new Value(
          t,
          t.equals("Float32")
              ? (double) Float.intBitsToFloat(random.nextInt())
              : Double.longBitsToDouble(random.nextLong()));
    if (t.startsWith("Complex")) {
      String component = t.equals("Complex64") ? "Float32" : "Float64";
      return complex(
          t, sample(component, random.nextInt(), bits), sample(component, random.nextInt(), bits));
    }
    if (t.equals("Symbol")) return new Value(t, new SymbolValue("same"));
    if (List.of("Unit", "Null", "Undefined").contains(t)) return absent(t);
    int max =
        t.equals("Bytes") ? 256 : t.equals("CodeUnit16") || t.equals("Utf16Text") ? 65536 : 1114112;
    if (List.of("Char", "CodePoint", "CodeUnit16").contains(t)) {
      int c;
      do {
        c = random.nextInt(max);
      } while (!validUnit(t, c));
      return character(t, c);
    }
    int[] xs = new int[random.nextInt(40)];
    for (int j = 0; j < xs.length; j++) {
      do {
        xs[j] = random.nextInt(max);
      } while (!validUnit(t, xs[j]));
    }
    return sequence(t, xs);
  }

  public static Value unit(Runnable operation) {
    operation.run();
    return absent("Unit");
  }

  public static Object toNative(String t, Value v, int bits) {
    v = convert(t, v, bits);
    if (integerType(t)) {
      BigInteger n = (BigInteger) v.data;
      return switch (t) {
        case "Int8" -> n.byteValueExact();
        case "Int16", "UInt8" -> n.shortValueExact();
        case "Int32", "UInt16" -> n.intValueExact();
        case "Int64", "UInt32" -> n.longValueExact();
        default -> n;
      };
    }
    if (t.equals("Char")) return new String(Character.toChars((int) v.data));
    if (t.equals("CodePoint")) return v.data;
    if (t.equals("CodeUnit16")) return (char) (int) v.data;
    if (t.equals("Bytes")) {
      List<?> xs = (List<?>) v.data;
      byte[] bytes = new byte[xs.size()];
      for (int i = 0; i < bytes.length; i++) bytes[i] = (byte) (int) xs.get(i);
      return bytes;
    }
    if (t.equals("Utf16Text")) {
      List<?> xs = (List<?>) v.data;
      char[] units = new char[xs.size()];
      for (int i = 0; i < units.length; i++) units[i] = (char) (int) xs.get(i);
      return new String(units);
    }
    if (t.equals("Float32")) return ((Double) v.data).floatValue();
    if (t.equals("Text")) {
      StringBuilder text = new StringBuilder();
      for (Object c : (List<?>) v.data) text.appendCodePoint((int) c);
      return text.toString();
    }
    return v.data;
  }

  public static Value fromNative(String t, Object value, int bits) {
    Value v;
    if (integerType(t)
        && !(value instanceof BigInteger
            || value instanceof Byte
            || value instanceof Short
            || value instanceof Integer
            || value instanceof Long
            || value instanceof Value))
      throw new IllegalArgumentException("invalid " + t + " representation");
    if (value instanceof Value scalar) v = scalar;
    else if (t.startsWith("Maybe ")) {
      if (value instanceof Nothing<?>) v = construct(t, "Maybe::Nothing", new Value[] {});
      else if (value instanceof Just<?> just) {
        v = construct(t, "Maybe::Just", new Value[] {fromNative(t.substring(6), just.value, bits)});
      } else throw new IllegalArgumentException("native Maybe requires Nothing or Just");
    } else if (t.startsWith("Either ")) {
      var arguments = eitherArguments(t);
      if (value instanceof Left<?, ?> left) {
        v =
            construct(
                t, "Either::Left", new Value[] {fromNative(arguments.get(0), left.value, bits)});
      } else if (value instanceof Right<?, ?> right) {
        v =
            construct(
                t, "Either::Right", new Value[] {fromNative(arguments.get(1), right.value, bits)});
      } else throw new IllegalArgumentException("native Either requires Left or Right");
    } else if (t.startsWith("List ")) {
      if (!(value instanceof List<?> values)) {
        throw new IllegalArgumentException("native List requires java.util.List");
      }
      var result = new ArrayList<Value>(values.size());
      for (Object field : values) result.add(fromNative(t.substring(5), field, bits));
      v = list(t, result);
    } else if (integerType(t))
      v =
          new Value(
              t,
              value instanceof BigInteger
                  ? value
                  : BigInteger.valueOf(((Number) value).longValue()));
    else if (t.equals("Char")) {
      int[] xs = ((String) value).codePoints().toArray();
      if (xs.length != 1) throw new IllegalArgumentException("Char requires one Unicode scalar");
      v = character(t, xs[0]);
    } else if (t.equals("CodePoint")) v = character(t, (int) value);
    else if (t.equals("CodeUnit16")) v = character(t, (char) value);
    else if (t.equals("Bytes")) {
      byte[] xs = (byte[]) value;
      int[] units = new int[xs.length];
      for (int i = 0; i < xs.length; i++) units[i] = Byte.toUnsignedInt(xs[i]);
      v = sequence(t, units);
    } else if (t.equals("Utf16Text")) v = sequence(t, ((String) value).chars().toArray());
    else if (t.startsWith("Float")) v = new Value(t, ((Number) value).doubleValue());
    else if (t.equals("Text")) v = sequence(t, ((String) value).codePoints().toArray());
    else v = new Value(t, value);
    return validate(t, v, bits);
  }

  private static double exactFloat(Ratio r, boolean single) {
    if (r.n.signum() == 0) return 0.0;
    boolean negative = r.n.signum() < 0;
    BigInteger n = r.n.abs(), d = r.d;
    int p = single ? 24 : 53,
        bias = single ? 127 : 1023,
        emin = 1 - bias,
        emax = bias,
        e = n.bitLength() - d.bitLength();
    if (e >= 0 ? n.compareTo(d.shiftLeft(e)) < 0 : n.shiftLeft(-e).compareTo(d) < 0) e--;
    if (e > emax) return negative ? Double.NEGATIVE_INFINITY : Double.POSITIVE_INFINITY;
    int scale = Math.max(e, emin) - (p - 1);
    BigInteger num = scale < 0 ? n.shiftLeft(-scale) : n, den = scale > 0 ? d.shiftLeft(scale) : d;
    BigInteger[] qr = num.divideAndRemainder(den);
    BigInteger q = qr[0];
    int cmp = qr[1].shiftLeft(1).compareTo(den);
    if (cmp > 0 || (cmp == 0 && q.testBit(0))) q = q.add(BigInteger.ONE);
    e = Math.max(e, emin);
    if (q.equals(BigInteger.ONE.shiftLeft(p))) {
      q = q.shiftRight(1);
      e++;
    }
    if (e > emax) return negative ? Double.NEGATIVE_INFINITY : Double.POSITIVE_INFINITY;
    BigInteger hidden = BigInteger.ONE.shiftLeft(p - 1);
    boolean subnormal = q.compareTo(hidden) < 0;
    long exponent = subnormal ? 0 : e + bias,
        mantissa = (subnormal ? q : q.subtract(hidden)).longValue();
    long bits = ((negative ? 1L : 0L) << (single ? 31 : 63)) | (exponent << (p - 1)) | mantissa;
    return single ? (double) Float.intBitsToFloat((int) bits) : Double.longBitsToDouble(bits);
  }

  public record Bound(String op, Value value) {}

  public record Domain(
      java.util.function.BiFunction<List<Value>, Integer, List<Value>> candidates,
      java.util.function.Predicate<List<Value>> accept) {}

  private static BigInteger floor(Ratio r) {
    BigInteger[] qr = r.n.divideAndRemainder(r.d);
    return qr[1].signum() < 0 ? qr[0].subtract(BigInteger.ONE) : qr[0];
  }

  private static BigInteger ceil(Ratio r) {
    return floor(new Ratio(r.n.negate(), r.d)).negate();
  }

  public static List<Value> domainCandidates(
      String t, int seed, int bits, Bound[] restrictions, Value[] hints) {
    var values = new ArrayList<Value>();
    for (Value hint : hints) {
      try {
        values.add(convert(t, hint, bits));
      } catch (RuntimeException ignored) {
      }
    }
    if (integerType(t)) {
      BigInteger lo = null, hi = null;
      if (t.equals("BigUInt")) lo = BigInteger.ZERO;
      else if (!List.of("Integer", "BigInt").contains(t)) {
        int w =
            t.endsWith("Size") || t.equals("UIntPtr")
                ? bits
                : Integer.parseInt(t.replaceAll("\\D", ""));
        boolean signed = t.startsWith("Int");
        lo = signed ? BigInteger.ONE.shiftLeft(w - 1).negate() : BigInteger.ZERO;
        hi = BigInteger.ONE.shiftLeft(signed ? w - 1 : w).subtract(BigInteger.ONE);
      }
      for (Bound b : restrictions) {
        Ratio r = ratio(b.value);
        if (List.of(">", ">=", "==").contains(b.op)) {
          BigInteger v = b.op.equals(">") ? floor(r).add(BigInteger.ONE) : ceil(r);
          lo = lo == null ? v : lo.max(v);
        }
        if (List.of("<", "<=", "==").contains(b.op)) {
          BigInteger v = b.op.equals("<") ? ceil(r).subtract(BigInteger.ONE) : floor(r);
          hi = hi == null ? v : hi.min(v);
        }
      }
      if (lo != null && hi != null && lo.compareTo(hi) > 0) return List.of();
      BigInteger lower =
          lo == null
              ? (hi == null ? BigInteger.ZERO : hi)
                  .min(BigInteger.ZERO)
                  .subtract(BigInteger.ONE.shiftLeft(256))
              : lo;
      BigInteger upper =
          hi == null
              ? (lo == null ? BigInteger.ZERO : lo)
                  .max(BigInteger.ZERO)
                  .add(BigInteger.ONE.shiftLeft(256))
              : hi;
      var ns =
          new ArrayList<BigInteger>(
              List.of(
                  lower,
                  upper,
                  BigInteger.ZERO,
                  BigInteger.ONE,
                  BigInteger.ONE.negate(),
                  lower.add(BigInteger.ONE),
                  upper.subtract(BigInteger.ONE)));
      Random random = new Random(seed);
      BigInteger width = upper.subtract(lower).add(BigInteger.ONE);
      for (int j = 0; j < 8; j++)
        ns.add(lower.add(new BigInteger(width.bitLength(), random).mod(width)));
      for (BigInteger n : ns) values.add(new Value(t, n));
      values.removeIf(
          v ->
              !integerType(v.type)
                  || ((BigInteger) v.data).compareTo(lower) < 0
                  || ((BigInteger) v.data).compareTo(upper) > 0);
      values.replaceAll(v -> convert(t, v, bits));
    } else for (int j = 0; j < 8; j++) values.add(sample(t, seed + j * 7919, bits));
    if (!values.isEmpty()) Collections.rotate(values, -Math.floorMod(seed, values.size()));
    return values;
  }

  public static List<Value> generateTuple(
      Domain[] domains, int seed, int attempts, List<Value> prefix) {
    int[] used = {0};
    while (used[0] < attempts) {
      var result = searchDomain(domains, seed, attempts, used, new ArrayList<>(prefix));
      if (result != null) return result;
    }
    throw new IllegalArgumentException(
        "refinement-generation-exhausted after "
            + used[0]
            + " attempts; prefix="
            + prefix
            + "; seed="
            + seed);
  }

  private static List<Value> searchDomain(
      Domain[] domains, int seed, int attempts, int[] used, List<Value> values) {
    if (values.size() == domains.length) return values;
    if (used[0] >= attempts) return null;
    used[0]++;
    Domain domain = domains[values.size()];
    for (Value value : domain.candidates.apply(values, seed + used[0] * 7919)) {
      if (used[0] >= attempts) break;
      used[0]++;
      var next = new ArrayList<>(values);
      next.add(value);
      if (domain.accept.test(next)) {
        var result = searchDomain(domains, seed, attempts, used, next);
        if (result != null) return result;
      }
    }
    return null;
  }

  public static void requireContract(boolean condition, String context) {
    if (!condition) throw new IllegalArgumentException(context);
  }

  public static Value contract(String context, boolean condition, Value result) {
    requireContract(condition, context);
    return result;
  }

  public static void refinedCase(
      Domain[] domains,
      int seed,
      int attempts,
      int shrinks,
      java.util.function.Consumer<List<Value>> check,
      String context) {
    List<Value> values;
    try {
      values = generateTuple(domains, seed, attempts, List.of());
    } catch (RuntimeException error) {
      throw new IllegalArgumentException(context + ": " + error.getMessage(), error);
    }
    try {
      check.accept(values);
    } catch (RuntimeException | AssertionError original) {
      var best = values;
      int budget = shrinks;
      for (int i = 0; i < best.size(); i++) {
        Value value = best.get(i);
        var candidates = new ArrayList<Value>(domains[i].candidates.apply(best.subList(0, i), 0));
        if (integerType(value.type)) {
          BigInteger initial = (BigInteger) value.data;
          candidates.add(0, new Value(value.type, BigInteger.ZERO));
          candidates.add(1, new Value(value.type, BigInteger.valueOf(initial.signum())));
          for (BigInteger v = initial.divide(BigInteger.TWO);
              v.abs().compareTo(BigInteger.ONE) > 0;
              v = v.divide(BigInteger.TWO)) candidates.add(2, new Value(value.type, v));
        }
        for (Value candidate : candidates) {
          if (budget-- <= 0) break;
          if (complexity(candidate).compareTo(complexity(best.get(i))) >= 0) continue;
          var prefix = new ArrayList<>(best.subList(0, i));
          prefix.add(candidate);
          if (!domains[i].accept.test(prefix)) continue;
          List<Value> trial;
          try {
            trial = generateTuple(domains, seed, Math.min(attempts, 100), prefix);
          } catch (IllegalArgumentException error) {
            if (error.getMessage().startsWith("refinement-generation-exhausted")) continue;
            throw error;
          }
          try {
            check.accept(trial);
          } catch (RuntimeException | AssertionError ignored) {
            best = trial;
          }
        }
      }
      throw new AssertionError(
          context
              + ": "
              + original.getMessage()
              + "; refined counterexample="
              + best
              + "; seed="
              + seed,
          original);
    }
  }

  private static BigInteger complexity(Value value) {
    if (integerType(value.type)) return ((BigInteger) value.data).abs();
    if (value.data instanceof Presence p)
      return p.present ? complexity(p.value).add(BigInteger.ONE) : BigInteger.ZERO;
    if (value.data instanceof List<?> xs) return BigInteger.valueOf(xs.size());
    if (value.data instanceof Boolean b) return b ? BigInteger.ONE : BigInteger.ZERO;
    if (value.data instanceof Double d)
      return BigInteger.valueOf(Double.doubleToRawLongBits(Math.abs(d)));
    if (value.data instanceof Complex c)
      return complexity(new Value("Float64", c.real))
          .add(complexity(new Value("Float64", c.imaginary)));
    if (exactType(value.type)) {
      Ratio r = ratio(value);
      return r.n.abs().add(r.d).subtract(BigInteger.ONE);
    }
    if (value.data instanceof Integer c) return BigInteger.valueOf(c);
    return value.data == null ? BigInteger.ZERO : BigInteger.ONE;
  }

  // Workflow runtime. A workflow runs under a runtime: a clock, a seeded
  // random source, a trace of what happened, and the state of stateful
  // stages. The runtime travels in the symbols map every generated method
  // takes; without one, the default runtime applies (real time, unless the
  // tests installed a virtual clock). Durations are long microseconds.

  private static final String WORKFLOW = "\0lawspec.workflow";

  /** Tells the time and waits, in microseconds. */
  public interface Clock {
    long now();

    void sleep(long micros);
  }

  /** Monotonic wall time. */
  public static final class RealClock implements Clock {
    public long now() {
      return System.nanoTime() / 1000;
    }

    public void sleep(long micros) {
      try {
        Thread.sleep(micros / 1000, (int) (micros % 1000) * 1000);
      } catch (InterruptedException error) {
        Thread.currentThread().interrupt();
        throw new IllegalStateException("workflow interrupted while waiting", error);
      }
    }
  }

  /** Advances when slept on and returns at once. */
  public static final class VirtualClock implements Clock {
    public long time;

    public long now() {
      return time;
    }

    public void sleep(long micros) {
      time += micros;
    }
  }

  /** The same sequence on every target for the same seed. */
  public static final class SplitMix64 {
    private long state;

    public SplitMix64(long seed) {
      state = seed;
    }

    public long next() {
      state += 0x9E3779B97F4A7C15L;
      long z = state;
      z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9L;
      z = (z ^ (z >>> 27)) * 0x94D049BB133111EBL;
      return z ^ (z >>> 31);
    }

    /** Uniform in [0, bound); 0 when bound is 0. */
    public long below(long bound) {
      return bound <= 0 ? 0 : Long.remainderUnsigned(next(), bound);
    }

    /** Uniform in [0, bound) for any bound up to 2^64; 0 when bound is 0. */
    public BigInteger below(BigInteger bound) {
      if (bound.signum() <= 0) return BigInteger.ZERO;
      return new BigInteger(Long.toUnsignedString(next())).mod(bound);
    }
  }

  /** A stage starting or finishing an attempt, or a wait. */
  public record TraceEvent(String kind, String stage, long number, boolean succeeded) {}

  /**
   * gates: whether rate limits, breakers, bulkheads and caches apply. The
   * runtime generated tests install has them off: a workflow law calls the
   * workflow and its composition, which would see each other's state.
   */
  public static final class WorkflowRuntime {
    public final Clock clock;
    public final SplitMix64 random;
    public final List<TraceEvent> trace = new ArrayList<>();
    public final Map<String, Object> state = new java.util.HashMap<>();
    public boolean gates = true;
    // A frame per running workflow: the undos of its completed stages.
    private final List<List<Map.Entry<String, Runnable>>> frames = new ArrayList<>();
    // When the running attempt of a stage with a timeout must end
    // (System.nanoTime), or null.
    private Long deadline;
    // The running attempt's hedge, or null.
    private Hedge hedge;

    public WorkflowRuntime(Clock clock, long seed) {
      this.clock = clock == null ? new RealClock() : clock;
      this.random = new SplitMix64(seed);
    }

    /** A symbols map that runs workflows under this runtime. */
    public Map<String, Object> context(Map<String, Object> symbols) {
      symbols.put(WORKFLOW, this);
      return symbols;
    }
  }

  private static WorkflowRuntime defaultRuntime;

  /** Makes the default runtime virtual, as generated tests do. */
  public static synchronized void useVirtualClock(long seed) {
    defaultRuntime = new WorkflowRuntime(new VirtualClock(), seed);
    defaultRuntime.gates = false;
  }

  public static synchronized WorkflowRuntime workflowRuntime(Map<String, Object> symbols) {
    if (symbols.get(WORKFLOW) instanceof WorkflowRuntime runtime) return runtime;
    if (defaultRuntime == null) defaultRuntime = new WorkflowRuntime(null, 0);
    return defaultRuntime;
  }

  /** What a custom strategy decides: a delay, or null to stop. */
  public interface Decide {
    Long decide(long attempt, Value failure, long previous);
  }

  /**
   * strategy is immediate, fixed, linear, exponential, fibonacci or custom;
   * delay, step, factor and cap (negative for none) are its parameters.
   */
  public record Retry(
      String strategy, long delay, long step, long factor, long cap, long attempts, String jitter,
      Function<Value, Boolean> when, Decide decide) {}

  /**
   * A stateful policy: start gives its state, admit a Step of the next state
   * and a Gate (Admit, WaitFor or Reject), and finish (when set) the state
   * after the call. waitMicros is -2 to fail at once when not admitted, -1
   * to wait without bound, or the most it waits.
   */
  public record Gate(
      String kind, java.util.function.LongFunction<Value> start, java.util.function.BiFunction<Value, Long, Value> admit,
      GateFinish finish, long waitMicros) {}

  public interface GateFinish {
    Value finish(Value state, long now, boolean succeeded);
  }

  /**
   * key names the stage's state; cache is how long a success is reused (0 or
   * less for none); wraps says failures are StageFailures; fail gives the
   * stage's result for a policy failure.
   */
  public record StagePolicy(
      String stage, Retry retry, long timeout, String key, List<Gate> gates, long cache, boolean wraps,
      Function<String, Value> fail, java.util.function.Consumer<Value> compensate, Hedge hedge) {
    public StagePolicy(String stage, Retry retry, long timeout) {
      this(stage, retry, timeout, stage, List.of(), -1, false, null, null, null);
    }
  }

  /**
   * When an attempt has not succeeded after delay microseconds, another
   * starts beside it, up to most in all; the first success wins.
   */
  public record Hedge(String stage, long delay, long most) {}

  /** Runs a workflow whose stages compensate: when it fails, its completed stages' undos run, last first. */
  public static Value runWorkflow(Map<String, Object> symbols, java.util.function.Supplier<Value> attempt) {
    WorkflowRuntime runtime = workflowRuntime(symbols);
    var frame = new ArrayList<Map.Entry<String, Runnable>>();
    runtime.frames.add(frame);
    Value result;
    try {
      result = attempt.get();
    } finally {
      runtime.frames.remove(runtime.frames.size() - 1);
    }
    if (result.data() instanceof Data data && data.tag().equals("Either::Left")) {
      for (int i = frame.size() - 1; i >= 0; i--) {
        runtime.trace.add(new TraceEvent("compensate", frame.get(i).getKey(), 0, true));
        frame.get(i).getValue().run();
      }
    }
    return result;
  }

  private record CacheEntry(Value key, Value value, long expires) {}

  private static final String STAGE_FAILURE = "lawspec.resilience::type::StageFailure::";
  private static final String GATE = "lawspec.resilience::type::Gate::";

  private static String passGate(WorkflowRuntime runtime, StagePolicy policy, Gate gate) {
    String key = policy.key() + "/" + gate.kind();
    String failure = switch (gate.kind()) {
      case "breaker" -> "CircuitOpen";
      case "limit" -> "RateLimited";
      default -> "Saturated";
    };
    long waited = 0;
    while (true) {
      long now = runtime.clock.now();
      Value state = runtime.state.containsKey(key) ? (Value) runtime.state.get(key) : gate.start().apply(now);
      Data step = (Data) gate.admit().apply(state, now).data();
      runtime.state.put(key, step.fields().get(0));
      Data decision = (Data) step.fields().get(1).data();
      if (decision.tag().equals(GATE + "Admit")) return null;
      if (decision.tag().equals(GATE + "Reject") || gate.waitMicros() == -2) return failure;
      long delay = ((BigInteger) decision.fields().get(0).data()).longValueExact();
      if (gate.waitMicros() >= 0 && waited + delay > gate.waitMicros()) return failure;
      runtime.trace.add(new TraceEvent("wait", policy.stage(), delay, true));
      runtime.clock.sleep(delay);
      waited += delay;
    }
  }

  private static void finishGate(WorkflowRuntime runtime, StagePolicy policy, Gate gate, boolean succeeded) {
    if (gate.finish() == null) return;
    String key = policy.key() + "/" + gate.kind();
    runtime.state.put(key, gate.finish().finish((Value) runtime.state.get(key), runtime.clock.now(), succeeded));
  }

  private static long fibonacci(long n) {
    long a = 1, b = 1;
    for (long i = 1; i < n; i++) {
      long next = a + b;
      a = b;
      b = next;
    }
    return a;
  }

  /** The delay before attempt (2 or more), before jitter. */
  public static long retryDelay(Retry retry, long attempt) {
    long n = attempt - 1;
    switch (retry.strategy()) {
      case "immediate":
        return 0;
      case "fixed":
        return retry.delay();
      case "linear":
        return retry.delay() + retry.step() * (n - 1);
      case "exponential": {
        long delay = retry.delay();
        for (long i = 1; i < n; i++) {
          delay *= retry.factor();
          if (retry.cap() >= 0 && delay >= retry.cap()) return retry.cap();
        }
        return retry.cap() >= 0 && delay > retry.cap() ? retry.cap() : delay;
      }
      case "fibonacci":
        return retry.delay() * fibonacci(n);
      default:
        throw new IllegalArgumentException("unknown retry strategy: " + retry.strategy());
    }
  }

  /** Full: [0, delay]; equal: delay/2 + [0, delay/2]; decorrelated: [base, previous * 3], capped at delay. */
  public static long jittered(String jitter, long delay, long previous, long base, SplitMix64 random) {
    switch (jitter) {
      case "full":
        return random.below(delay + 1);
      case "equal": {
        long half = delay / 2;
        return half + random.below(delay - half + 1);
      }
      case "decorrelated": {
        long high = Math.max(base, previous * 3);
        return Math.min(delay, base + random.below(high - base + 1));
      }
      default:
        return delay;
    }
  }

  /** Runs a stage's attempts under its policy; a Left is a failure. */
  public static Value runStage(Map<String, Object> symbols, StagePolicy policy, java.util.function.Supplier<Value> attempt) {
    return runStage(symbols, policy, attempt, null);
  }

  /** As runStage; key is the stage's input, for the cache. */
  @SuppressWarnings("unchecked")
  public static Value runStage(
      Map<String, Object> symbols, StagePolicy policy, java.util.function.Supplier<Value> attempt, Value key) {
    WorkflowRuntime runtime = workflowRuntime(symbols);
    List<Gate> gates = runtime.gates ? policy.gates() : List.of();
    String cacheKey = policy.key() + "/cache";
    boolean caching = policy.cache() > 0 && runtime.gates;
    if (caching) {
      long now = runtime.clock.now();
      for (var entry : (List<CacheEntry>) runtime.state.getOrDefault(cacheKey, List.of())) {
        if (now < entry.expires() && compareValues(entry.key(), key) == 0) {
          runtime.trace.add(new TraceEvent("cached", policy.stage(), 0, true));
          return entry.value();
        }
      }
    }
    for (int i = 0; i < gates.size(); i++) {
      String failure = passGate(runtime, policy, gates.get(i));
      if (failure != null) {
        for (var passed : gates.subList(0, i)) finishGate(runtime, policy, passed, false);
        return policy.fail().apply(failure);
      }
    }
    Value result = attempts(runtime, policy, attempt);
    boolean succeeded = !(result.data() instanceof Data data && data.tag().equals("Either::Left"));
    for (var gate : gates) finishGate(runtime, policy, gate, succeeded);
    if (succeeded && policy.compensate() != null && !runtime.frames.isEmpty()) {
      Value value = ((Data) result.data()).fields().get(0);
      runtime.frames.get(runtime.frames.size() - 1).add(Map.entry(policy.stage(), () -> policy.compensate().accept(value)));
    }
    if (caching && succeeded) {
      var entries = new ArrayList<CacheEntry>();
      for (var entry : (List<CacheEntry>) runtime.state.getOrDefault(cacheKey, List.of()))
        if (compareValues(entry.key(), key) != 0) entries.add(entry);
      entries.add(new CacheEntry(key, result, runtime.clock.now() + policy.cache()));
      runtime.state.put(cacheKey, entries);
    }
    return result;
  }

  /** Raised by awaitWithin when an attempt outlives its stage's timeout. */
  private static final class TimedOut extends RuntimeException {
    TimedOut() { super("timed out", null, false, false); }
  }

  /**
   * An asynchronous step's logical result: start begins the step and convert
   * turns its native result into a logical value. The step runs within its
   * stage's timeout and hedge, if any.
   */
  public static <T> Value awaitStep(
      Map<String, Object> symbols, java.util.function.Supplier<java.util.concurrent.CompletableFuture<T>> start,
      Function<T, Value> convert) {
    WorkflowRuntime runtime = workflowRuntime(symbols);
    Long deadline = runtime.deadline;
    Hedge hedge = runtime.hedge;
    if (deadline == null && hedge == null) return convert.apply(start.get().join());
    long most = hedge == null ? 1 : hedge.most();
    var pending = new ArrayList<java.util.concurrent.CompletableFuture<T>>();
    long started = 0, next = Long.MAX_VALUE;
    boolean launch = true;
    try {
      while (true) {
        if (launch) {
          started++;
          if (started > 1) runtime.trace.add(new TraceEvent("hedge", hedge.stage(), started, true));
          pending.add(start.get());
          next = started < most ? System.nanoTime() + hedge.delay() * 1000 : Long.MAX_VALUE;
          launch = false;
        }
        long until = Math.min(next, deadline == null ? Long.MAX_VALUE : deadline);
        var any = java.util.concurrent.CompletableFuture.anyOf(pending.toArray(new java.util.concurrent.CompletableFuture<?>[0]));
        try {
          if (until == Long.MAX_VALUE) any.get();
          else any.get(Math.max(0, until - System.nanoTime()), java.util.concurrent.TimeUnit.NANOSECONDS);
        } catch (java.util.concurrent.TimeoutException | java.util.concurrent.ExecutionException e) {
          // A failed step is raised below; a timer passing is handled below.
        }
        Value last = null;
        for (var task : List.copyOf(pending)) {
          if (!task.isDone()) continue;
          pending.remove(task);
          Value value = convert.apply(task.join());
          if (!(value.data() instanceof Data data && data.tag().equals("Either::Left"))) return value;
          last = value;
        }
        long now = System.nanoTime();
        if (deadline != null && now >= deadline) throw new TimedOut();
        if (pending.isEmpty()) {
          if (started >= most) return last;
          launch = true;
        } else if (now >= next) {
          launch = true;
        }
      }
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new java.util.concurrent.CompletionException(e);
    } finally {
      for (var task : pending) task.cancel(true);
    }
  }

  /**
   * An attempt under its stage's timeout (failing with TimedOut when it
   * outlives it) and hedge. Under the runtime generated tests install (gates
   * off), both are off.
   */
  private static Value scoped(WorkflowRuntime runtime, StagePolicy policy, java.util.function.Supplier<Value> attempt) {
    if (!runtime.gates || (policy.timeout() <= 0 && policy.hedge() == null)) return attempt.get();
    Long outer = runtime.deadline;
    Hedge outerHedge = runtime.hedge;
    if (policy.timeout() > 0) runtime.deadline = System.nanoTime() + policy.timeout() * 1000;
    if (policy.hedge() != null) runtime.hedge = new Hedge(policy.stage(), policy.hedge().delay(), policy.hedge().most());
    try {
      return attempt.get();
    } catch (RuntimeException e) {
      // Callers may have wrapped the timeout with context.
      for (Throwable cause = e; cause != null; cause = cause.getCause()) {
        if (cause instanceof TimedOut) {
          return policy.fail() != null ? policy.fail().apply("TimedOut")
              : new Value("Either", new Data("Either::Left", List.of(new Value(STAGE_FAILURE, new Data(STAGE_FAILURE + "TimedOut", List.of())))));
        }
      }
      throw e;
    } finally {
      runtime.deadline = outer;
      runtime.hedge = outerHedge;
    }
  }

  private static Value attempts(WorkflowRuntime runtime, StagePolicy policy, java.util.function.Supplier<Value> attempt) {
    Retry retry = policy.retry();
    long number = 1, previous = 0;
    while (true) {
      runtime.trace.add(new TraceEvent("start", policy.stage(), number, false));
      Value result = scoped(runtime, policy, attempt);
      boolean failed = result.data() instanceof Data data && data.tag().equals("Either::Left");
      runtime.trace.add(new TraceEvent("finish", policy.stage(), number, !failed));
      if (!failed || retry == null) return result;
      if (retry.attempts() > 0 && number >= retry.attempts()) return result;
      Value failure = ((Data) result.data()).fields().get(0);
      if (policy.wraps()) {
        // Only the step's own failures and timeouts are retried.
        Data wrapped = (Data) failure.data();
        if (wrapped.tag().equals(STAGE_FAILURE + "StepFailed")) failure = wrapped.fields().get(0);
        else if (!wrapped.tag().equals(STAGE_FAILURE + "TimedOut")) return result;
      }
      if (retry.when() != null && !retry.when().apply(failure)) return result;
      number++;
      long delay;
      if (retry.strategy().equals("custom")) {
        Long wait = retry.decide().decide(number, failure, previous);
        if (wait == null) return result;
        delay = wait;
      } else {
        long base = retry.strategy().equals("immediate") ? 0 : retryDelay(retry, 2);
        delay = jittered(retry.jitter(), retryDelay(retry, number), previous, base, runtime.random);
      }
      runtime.trace.add(new TraceEvent("sleep", policy.stage(), delay, true));
      runtime.clock.sleep(delay);
      previous = delay;
    }
  }

  /** A logical Duration of whole microseconds. */
  public static Value duration(long micros) {
    return new Value("lawspec.time::type::Duration",
        new Data("lawspec.time::type::Duration::Duration", List.of(new Value("Integer", BigInteger.valueOf(micros)))));
  }

  /** A RetryDecision's delay, or null to stop. */
  public static Long retryDecision(Value decision) {
    Data data = (Data) decision.data();
    if (!data.tag().equals("lawspec.time::type::RetryDecision::RetryAfter")) return null;
    Data delay = (Data) data.fields().get(0).data();
    return ((BigInteger) delay.fields().get(0).data()).longValueExact();
  }

  /** A logical Integer. */
  public static Value integer64(long n) {
    return new Value("Integer", BigInteger.valueOf(n));
  }

  // Portable generation for stateful models. A type descriptor is an
  // s-expression: (int T lo hi) with _ for no bound, (bool), (text), (unit),
  // (list D), (maybe D), (either L R), (data NAME (ctor TAG D...) ...) and
  // (ref NAME) for a data type declared in the model's table. Every target
  // generates, shrinks and renders the same values for the same seed.

  /** A string atom of a descriptor. */
  public record Quoted(String text) {}

  /**
   * Parses s-expressions: lists (List), integers (BigInteger), strings
   * (Quoted), symbols (String) and _ (null).
   */
  public static List<Object> readDescriptor(String text) {
    var position = new int[] {0};
    var items = new ArrayList<Object>();
    skipBlank(text, position);
    while (position[0] < text.length()) {
      items.add(descriptorItem(text, position));
      skipBlank(text, position);
    }
    return items;
  }

  private static void skipBlank(String text, int[] position) {
    while (position[0] < text.length() && " \t\r\n".indexOf(text.charAt(position[0])) >= 0)
      position[0]++;
  }

  private static Object descriptorItem(String text, int[] position) {
    skipBlank(text, position);
    char c = text.charAt(position[0]);
    if (c == '(') {
      position[0]++;
      var items = new ArrayList<Object>();
      skipBlank(text, position);
      while (text.charAt(position[0]) != ')') {
        items.add(descriptorItem(text, position));
        skipBlank(text, position);
      }
      position[0]++;
      return items;
    }
    if (c == '"') {
      position[0]++;
      var out = new StringBuilder();
      while (text.charAt(position[0]) != '"') {
        if (text.charAt(position[0]) == '\\') position[0]++;
        out.append(text.charAt(position[0]));
        position[0]++;
      }
      position[0]++;
      return new Quoted(out.toString());
    }
    int start = position[0];
    while (position[0] < text.length() && " \t\r\n()".indexOf(text.charAt(position[0])) < 0)
      position[0]++;
    String atom = text.substring(start, position[0]);
    if (atom.equals("_")) return null;
    String digits = atom.replaceFirst("^-+", "");
    if (!digits.isEmpty() && digits.chars().allMatch(d -> d >= '0' && d <= '9'))
      return new BigInteger(atom);
    return atom;
  }

  /** An atom's text: a symbol, a string or an integer. */
  private static String atomText(Object atom) {
    return atom instanceof Quoted q ? q.text() : String.valueOf(atom);
  }

  private static boolean sameAtom(Object a, Object b) {
    boolean textA = a instanceof String || a instanceof Quoted;
    boolean textB = b instanceof String || b instanceof Quoted;
    if (textA || textB) return textA && textB && atomText(a).equals(atomText(b));
    return Objects.equals(a, b);
  }

  @SuppressWarnings("unchecked")
  private static List<Object> form(Object d) {
    return (List<Object>) d;
  }

  private static final BigInteger UNBOUNDED = BigInteger.valueOf(1_000_000);

  /** Generation, shrinking and rendering over a table of data types. */
  public static final class Values {
    public final Map<String, List<Object>> table;

    public Values(Map<String, List<Object>> table) {
      this.table = table;
    }

    public List<Object> resolve(Object d) {
      var f = form(d);
      return atomText(f.get(0)).equals("ref") ? table.get(atomText(f.get(1))) : f;
    }

    /**
     * An integer's range: a missing bound is 1,000,000 from zero, or
     * 2,000,000 from the other bound when that is beyond it.
     */
    public BigInteger[] bounds(List<Object> d) {
      var lo = (BigInteger) d.get(2);
      var hi = (BigInteger) d.get(3);
      var twice = UNBOUNDED.shiftLeft(1);
      if (lo == null && hi == null) return new BigInteger[] {UNBOUNDED.negate(), UNBOUNDED};
      if (lo == null) return new BigInteger[] {UNBOUNDED.negate().min(hi.subtract(twice)), hi};
      if (hi == null) return new BigInteger[] {lo, UNBOUNDED.max(lo.add(twice))};
      return new BigInteger[] {lo, hi};
    }

    /** The constructors whose fields mention no data type. */
    public List<Object> base(List<Object> d) {
      var all = d.subList(2, d.size());
      var found = new ArrayList<Object>();
      for (var c : all) {
        var ctor = form(c);
        boolean mentions = false;
        for (var f : ctor.subList(2, ctor.size())) mentions |= mentionsData(f);
        if (!mentions) found.add(c);
      }
      return found.isEmpty() ? all : found;
    }

    /** The logical type name of a descriptor's values. */
    public String typeName(Object descriptor) {
      var d = form(descriptor);
      return switch (atomText(d.get(0))) {
        case "int" -> atomText(d.get(1));
        case "bool" -> "Bool";
        case "text" -> "Text";
        case "unit" -> "Unit";
        case "list" -> "List " + typeName(d.get(1));
        case "maybe" -> "Maybe " + typeName(d.get(1));
        case "either" -> "Either (" + typeName(d.get(1)) + ") (" + typeName(d.get(2)) + ")";
        default -> atomText(d.get(1));
      };
    }

    private static Value text(List<Integer> units) {
      return new Value("Text", List.copyOf(units));
    }

    private static Value data(String type, String tag, List<Value> fields) {
      return new Value(type, new Data(tag, fields));
    }

    public Value generate(Object descriptor, SplitMix64 random, long size) {
      var d = resolve(descriptor);
      var type = typeName(d);
      switch (atomText(d.get(0))) {
        case "int" -> {
          var b = bounds(d);
          var lo = b[0];
          var hi = b[1];
          if (random.below(10) < 2) {
            var specials =
                List.of(
                    lo,
                    hi,
                    BigInteger.ZERO.max(lo).min(hi),
                    BigInteger.ONE.max(lo).min(hi));
            return new Value(type, specials.get((int) random.below(4)));
          }
          return new Value(type, lo.add(random.below(hi.subtract(lo).add(BigInteger.ONE))));
        }
        case "bool" -> {
          return bool(random.below(2) == 1);
        }
        case "text" -> {
          long n = random.below(size + 1);
          var units = new ArrayList<Integer>();
          for (long i = 0; i < n; i++) units.add(32 + (int) random.below(95));
          return text(units);
        }
        case "unit" -> {
          return absent("Unit");
        }
        case "list" -> {
          long n = random.below(size + 1);
          var items = new ArrayList<Value>();
          for (long i = 0; i < n; i++) items.add(generate(d.get(1), random, size));
          return new Value(type, List.copyOf(items));
        }
        case "maybe" -> {
          if (random.below(4) == 0) return data(type, "Maybe::Nothing", List.of());
          return data(type, "Maybe::Just", List.of(generate(d.get(1), random, size)));
        }
        case "either" -> {
          if (random.below(2) == 0)
            return data(type, "Either::Left", List.of(generate(d.get(1), random, size)));
          return data(type, "Either::Right", List.of(generate(d.get(2), random, size)));
        }
        case "data" -> {
          var choices = size <= 0 ? base(d) : d.subList(2, d.size());
          var ctor = form(choices.get((int) random.below(choices.size())));
          var fields = new ArrayList<Value>();
          for (var f : ctor.subList(2, ctor.size()))
            fields.add(generate(f, random, Math.max(size - 1, 0)));
          return data(type, atomText(ctor.get(1)), fields);
        }
        default -> throw new IllegalArgumentException("unknown descriptor " + d);
      }
    }

    public Value minimal(Object descriptor) {
      var d = resolve(descriptor);
      var type = typeName(d);
      switch (atomText(d.get(0))) {
        case "int" -> {
          var b = bounds(d);
          return new Value(type, BigInteger.ZERO.max(b[0]).min(b[1]));
        }
        case "bool" -> {
          return bool(false);
        }
        case "text" -> {
          return text(List.of());
        }
        case "unit" -> {
          return absent("Unit");
        }
        case "list" -> {
          return new Value(type, List.of());
        }
        case "maybe" -> {
          return data(type, "Maybe::Nothing", List.of());
        }
        case "either" -> {
          return data(type, "Either::Left", List.of(minimal(d.get(1))));
        }
        default -> {
          var ctor = form(base(d).get(0));
          var fields = new ArrayList<Value>();
          for (var f : ctor.subList(2, ctor.size())) fields.add(minimal(f));
          return data(type, atomText(ctor.get(1)), fields);
        }
      }
    }

    /** Smaller candidates for v, most aggressive first. */
    @SuppressWarnings("unchecked")
    public List<Value> shrink(Object descriptor, Value v) {
      var d = resolve(descriptor);
      var type = typeName(d);
      var out = new ArrayList<Value>();
      switch (atomText(d.get(0))) {
        case "int" -> {
          var target = (BigInteger) minimal(d).data();
          var n = (BigInteger) v.data();
          if (!n.equals(target)) {
            out.add(new Value(type, target));
            out.add(new Value(type, n.subtract(n.subtract(target).divide(BigInteger.TWO))));
            out.add(
                new Value(type, n.subtract(n.compareTo(target) > 0 ? BigInteger.ONE : BigInteger.ONE.negate())));
          }
        }
        case "bool" -> {
          if ((Boolean) v.data()) out.add(bool(false));
        }
        case "text" -> {
          var units = (List<Integer>) v.data();
          if (!units.isEmpty()) {
            out.add(text(List.of()));
            out.add(text(units.subList(0, units.size() / 2)));
            for (int i = 0; i < units.size(); i++) {
              var without = new ArrayList<>(units);
              without.remove(i);
              out.add(text(without));
            }
          }
        }
        case "list" -> {
          var items = (List<Value>) v.data();
          if (!items.isEmpty()) {
            out.add(new Value(type, List.of()));
            out.add(new Value(type, List.copyOf(items.subList(0, items.size() / 2))));
            for (int i = 0; i < items.size(); i++) {
              var without = new ArrayList<>(items);
              without.remove(i);
              out.add(new Value(type, List.copyOf(without)));
            }
            for (int i = 0; i < items.size(); i++) {
              for (var c : shrink(d.get(1), items.get(i))) {
                var replaced = new ArrayList<>(items);
                replaced.set(i, c);
                out.add(new Value(type, List.copyOf(replaced)));
              }
            }
          }
        }
        case "maybe" -> {
          var value = (Data) v.data();
          if (value.tag().equals("Maybe::Just")) {
            out.add(data(type, "Maybe::Nothing", List.of()));
            for (var c : shrink(d.get(1), value.fields().get(0)))
              out.add(data(type, "Maybe::Just", List.of(c)));
          }
        }
        case "either" -> {
          var value = (Data) v.data();
          var inner = value.tag().equals("Either::Left") ? d.get(1) : d.get(2);
          for (var c : shrink(inner, value.fields().get(0)))
            out.add(data(type, value.tag(), List.of(c)));
        }
        case "data" -> {
          var value = (Data) v.data();
          List<Object> ctor = null;
          for (var c : d.subList(2, d.size()))
            if (atomText(form(c).get(1)).equals(value.tag())) {
              ctor = form(c);
              break;
            }
          if (ctor == null) throw new IllegalArgumentException("unknown constructor " + value.tag());
          var fieldTypes = ctor.subList(2, ctor.size());
          int count = Math.min(value.fields().size(), fieldTypes.size());
          out.add(minimal(d));
          // A field of the same type is a smaller value of it.
          for (int i = 0; i < count; i++) {
            if (fieldTypes.get(i) instanceof List<?> fd
                && fd.size() == 2
                && sameAtom(fd.get(0), "ref")
                && sameAtom(fd.get(1), d.get(1))) out.add(value.fields().get(i));
          }
          for (int i = 0; i < count; i++) {
            for (var c : shrink(fieldTypes.get(i), value.fields().get(i))) {
              var replaced = new ArrayList<>(value.fields());
              replaced.set(i, c);
              out.add(data(type, value.tag(), replaced));
            }
          }
        }
        default -> {}
      }
      var original = render(v);
      var seen = new java.util.HashSet<String>();
      var unique = new ArrayList<Value>();
      for (var c : out) {
        var text = render(c);
        if (!text.equals(original) && seen.add(text)) unique.add(c);
      }
      return unique;
    }
  }

  private static boolean mentionsData(Object d) {
    if (!(d instanceof List<?> f)) return false;
    var head = atomText(f.get(0));
    if (head.equals("ref") || head.equals("data")) return true;
    for (var x : f.subList(1, f.size())) if (mentionsData(x)) return true;
    return false;
  }

  /** A value's canonical text, the same on every target. */
  public static String render(Value v) {
    Object data = v.data();
    if (data instanceof Boolean b) return b ? "true" : "false";
    if (data instanceof BigInteger n) return n.toString();
    if (data instanceof Handle h) return handleLabel(v.type(), h.target());
    if (v.type().equals("Text") && data instanceof List<?> units) {
      var out = new StringBuilder("\"");
      for (Object unit : units) {
        int c = (Integer) unit;
        if (c == '\\') out.append("\\\\");
        else if (c == '"') out.append("\\\"");
        else out.appendCodePoint(c);
      }
      return out.append('"').toString();
    }
    if (data == null) return "()";
    if (data instanceof List<?> items) {
      var parts = new ArrayList<String>();
      for (Object item : items) parts.add(render((Value) item));
      return "[" + String.join(", ", parts) + "]";
    }
    if (data instanceof Data value) {
      String tag = value.tag();
      int cut = tag.lastIndexOf("::");
      String name = cut < 0 ? tag : tag.substring(cut + 2);
      if (value.fields().isEmpty()) return name;
      var parts = new ArrayList<String>();
      for (Value field : value.fields()) parts.add(render(field));
      return name + "(" + String.join(", ", parts) + ")";
    }
    return String.valueOf(data);
  }

  /** A descriptor text's data types and its last form, the one generated. */
  public record Described(Values values, Object descriptor) {}

  public static Described valuesFrom(String text) {
    var forms = readDescriptor(text);
    var table = new java.util.HashMap<String, List<Object>>();
    for (var f : forms)
      if (f instanceof List<?> && atomText(form(f).get(0)).equals("data"))
        table.put(atomText(form(f).get(1)), form(f));
    return new Described(new Values(table), forms.getLast());
  }

  /** count values generated from one SplitMix64 seed, rendered. */
  public static List<String> generated(String text, long seed, long size, long count) {
    var described = valuesFrom(text);
    var random = new SplitMix64(seed);
    var result = new ArrayList<String>();
    for (long i = 0; i < count; i++)
      result.add(render(described.values().generate(described.descriptor(), random, size)));
    return result;
  }

  /** The shrink candidates of the first value generated, rendered. */
  public static List<String> shrunk(String text, long seed, long size) {
    var described = valuesFrom(text);
    var values = described.values();
    var first = values.generate(described.descriptor(), new SplitMix64(seed), size);
    var result = new ArrayList<String>();
    for (var c : values.shrink(described.descriptor(), first)) result.add(render(c));
    return result;
  }

  // Stateful models. A model's spec (see LawSpec.MachineSpec) lists its data
  // types, start and commands; the callbacks beside it are the generated
  // definitions that call the adapters, the references over the model state,
  // preconditions, the abstraction and invariants, each taking symbols first.
  // A run is generated by simulating the pure model, so every command in it is
  // allowed by typestate, its precondition and its reference; it is then
  // executed against the adapters and every result, abstracted state and
  // invariant is checked. A failing run is shrunk by dropping commands and
  // shrinking arguments, replaying the model to keep each candidate valid.

  /** A generated definition: symbols first, then its arguments. */
  public interface ModelCallback {
    Value apply(Map<String, Object> symbols, List<Value> args);
  }

  /** A command of a model: its spec form and its callbacks. */
  public static final class ModelCommand {
    final String name;
    final List<Object> arguments;
    final int state;
    final boolean unit;
    final List<Object> needs;
    final List<Object> shifts;
    /** The argument naming the key the command touches, for per-key checks; -1 for none. */
    final int key;
    final ModelCallback run;
    final ModelCallback reference;
    final ModelCallback when;

    ModelCommand(List<Object> form, ModelCallback[] callbacks) {
      var fields = new java.util.HashMap<String, List<Object>>();
      for (var f : form.subList(2, form.size())) {
        var field = form(f);
        fields.put(atomText(field.get(0)), field.subList(1, field.size()));
      }
      name = atomText(form.get(1));
      arguments = fields.get("arguments");
      state = ((BigInteger) fields.get("state").get(0)).intValueExact();
      unit = atomText(fields.get("unit").get(0)).equals("true");
      needs = fields.get("needs");
      shifts = fields.get("shifts");
      var keyField = fields.getOrDefault("key", List.of("none"));
      key = keyField.get(0) instanceof BigInteger k ? k.intValueExact() : -1;
      run = callbacks[0];
      reference = callbacks[1];
      when = callbacks.length > 2 ? callbacks[2] : null;
    }

    boolean admits(List<BigInteger> indices) {
      int n = Math.min(needs.size(), indices.size());
      for (int k = 0; k < n; k++) {
        var need = form(needs.get(k));
        var bound = (BigInteger) need.get(1);
        var i = indices.get(k);
        boolean ok =
            atomText(need.get(0)).equals("atleast") ? i.compareTo(bound) >= 0 : i.equals(bound);
        if (!ok) return false;
      }
      return true;
    }

    List<BigInteger> shifted(List<BigInteger> indices) {
      int n = Math.min(shifts.size(), indices.size());
      var out = new ArrayList<BigInteger>();
      for (int k = 0; k < n; k++) {
        var shift = form(shifts.get(k));
        var by = (BigInteger) shift.get(1);
        out.add(atomText(shift.get(0)).equals("by") ? indices.get(k).add(by) : by);
      }
      return out;
    }
  }

  /** A model: its spec and the generated definitions beside it. */
  public static final class Model {
    final String name;
    final boolean shared;
    final Values values;
    final List<BigInteger> startIndices;
    final List<Object> startArguments;
    final ModelCallback startRun;
    final ModelCallback startModel;
    final List<ModelCommand> commands;
    final ModelCallback abstractState;
    final List<String> invariantKinds;
    final List<ModelCallback> invariants;
    final boolean perKey;

    /**
     * start: run, model; each command: run, reference, when (null when
     * absent); abstractState may be null.
     */
    public Model(
        String spec,
        ModelCallback[] start,
        ModelCallback[][] commands,
        ModelCallback abstractState,
        ModelCallback[] invariants) {
      var forms = readDescriptor(spec);
      var machine = form(forms.get(0));
      name = atomText(machine.get(1));
      shared = atomText(machine.get(2)).equals("shared");
      var table = new java.util.HashMap<String, List<Object>>();
      List<Object> startForm = null;
      List<Object> invariantForm = null;
      var commandForms = new ArrayList<List<Object>>();
      boolean keyed = false;
      for (var f : forms) {
        var item = form(f);
        switch (atomText(item.get(0))) {
          case "data" -> table.put(atomText(item.get(1)), item);
          case "start" -> {
            if (startForm == null) startForm = item;
          }
          case "command" -> commandForms.add(item);
          case "invariants" -> {
            if (invariantForm == null) invariantForm = item;
          }
          case "perkey" -> {
            if (item.size() > 1 && atomText(item.get(1)).equals("true")) keyed = true;
          }
          default -> {}
        }
      }
      values = new Values(table);
      var startFields = new java.util.HashMap<String, List<Object>>();
      for (var f : startForm.subList(1, startForm.size())) {
        var field = form(f);
        startFields.put(atomText(field.get(0)), field.subList(1, field.size()));
      }
      var indices = new ArrayList<BigInteger>();
      for (var i : startFields.getOrDefault("indices", List.of())) indices.add((BigInteger) i);
      startIndices = indices;
      startArguments = startFields.getOrDefault("arguments", List.of());
      startRun = start[0];
      startModel = start[1];
      var built = new ArrayList<ModelCommand>();
      for (int k = 0; k < Math.min(commandForms.size(), commands.length); k++)
        built.add(new ModelCommand(commandForms.get(k), commands[k]));
      this.commands = built;
      this.abstractState = abstractState;
      var kinds = new ArrayList<String>();
      var checks = new ArrayList<ModelCallback>();
      var invariantList = invariants == null ? new ModelCallback[0] : invariants;
      int n = Math.min(invariantForm.size() - 1, invariantList.length);
      for (int k = 0; k < n; k++) {
        kinds.add(atomText(invariantForm.get(k + 1)));
        checks.add(invariantList[k]);
      }
      invariantKinds = kinds;
      this.invariants = checks;
      perKey = keyed;
    }
  }

  /** A command the model does not allow here. */
  private static final class InvalidStep extends RuntimeException {
    InvalidStep() {
      super(null, null, false, false);
    }
  }

  private record ModelStep(int index, List<Value> args) {}

  private record ModelRun(List<Value> startArgs, List<ModelStep> steps) {}

  private record ModelFailure(int step, String message) {}

  private record Stepped(Value state, Value result) {}

  private static List<Value> withLast(List<Value> args, Value last) {
    var full = new ArrayList<Value>(args);
    full.add(last);
    return full;
  }

  /** The model states along a run; throws InvalidStep. */
  private static List<Value> simulate(Model model, Map<String, Object> symbols, ModelRun run) {
    Value state;
    try {
      state = model.startModel.apply(symbols, run.startArgs());
    } catch (Exception e) {
      throw new InvalidStep();
    }
    var indices = model.startIndices;
    var states = new ArrayList<Value>();
    states.add(state);
    for (var step : run.steps()) {
      var command = model.commands.get(step.index());
      if (!command.admits(indices)) throw new InvalidStep();
      state = stepModel(command, symbols, step.args(), state).state();
      indices = command.shifted(indices);
      states.add(state);
    }
    return states;
  }

  private static Stepped stepModel(
      ModelCommand command, Map<String, Object> symbols, List<Value> args, Value state) {
    Value out;
    try {
      if (command.when != null && !truth(command.when.apply(symbols, List.of(state))))
        throw new InvalidStep();
      out = command.reference.apply(symbols, withLast(args, state));
    } catch (InvalidStep e) {
      throw e;
    } catch (Exception e) {
      throw new InvalidStep();
    }
    if (command.unit) return new Stepped(out, absent("Unit"));
    var fields = ((Data) out.data()).fields();
    return new Stepped(fields.get(1), fields.get(0));
  }

  private static List<Value> generateAll(Values values, List<Object> descriptors, SplitMix64 random, long size) {
    var out = new ArrayList<Value>();
    for (var d : descriptors) out.add(values.generate(d, random, size));
    return out;
  }

  private static ModelRun generateRun(Model model, SplitMix64 random, long length, long size) {
    Map<String, Object> symbols = new java.util.HashMap<String, Object>();
    var startArgs = generateAll(model.values, model.startArguments, random, size);
    Value state;
    try {
      state = model.startModel.apply(symbols, startArgs);
    } catch (Exception e) {
      return new ModelRun(startArgs, List.of());
    }
    var indices = model.startIndices;
    var steps = new ArrayList<ModelStep>();
    for (long n = 0; n < length; n++) {
      var allowed = new ArrayList<Integer>();
      for (int i = 0; i < model.commands.size(); i++)
        if (model.commands.get(i).admits(indices)) allowed.add(i);
      if (allowed.isEmpty()) break;
      int index = allowed.get((int) random.below(allowed.size()));
      var command = model.commands.get(index);
      var args = generateAll(model.values, command.arguments, random, size);
      try {
        state = stepModel(command, symbols, args, state).state();
      } catch (InvalidStep e) {
        continue;
      }
      steps.add(new ModelStep(index, args));
      indices = command.shifted(indices);
    }
    return new ModelRun(startArgs, steps);
  }

  /**
   * null when the system agrees with the model along the run; otherwise the
   * failing step's number and what went wrong.
   */
  private static ModelFailure execute(Model model, ModelRun run) {
    Map<String, Object> symbols = new java.util.HashMap<String, Object>();
    int step = 0;
    try {
      var state = model.startRun.apply(symbols, run.startArgs());
      var expected = model.startModel.apply(symbols, run.startArgs());
      var failure = checkState(model, symbols, state, expected);
      if (failure != null) return new ModelFailure(step, failure);
      for (var s : run.steps()) {
        step++;
        var command = model.commands.get(s.index());
        var full = new ArrayList<Value>(s.args());
        full.add(command.state, state);
        var out = command.run.apply(symbols, full);
        Value result;
        if (model.shared) {
          result = out;
        } else {
          var fields = ((Data) out.data()).fields();
          result = command.unit ? absent("Unit") : fields.get(0);
          state = fields.get(fields.size() - 1);
        }
        var stepped = stepModel(command, symbols, s.args(), expected);
        expected = stepped.state();
        var wanted = stepped.result();
        if (!command.unit && compareValues(result, wanted) != 0)
          return new ModelFailure(
              step, "returned " + render(result) + "; the model returns " + render(wanted));
        failure = checkState(model, symbols, state, expected);
        if (failure != null) return new ModelFailure(step, failure);
      }
    } catch (InvalidStep e) {
      return new ModelFailure(step, "the model does not allow this step");
    } catch (Exception e) {
      String message = e.getMessage();
      return new ModelFailure(
          step,
          "raised " + e.getClass().getSimpleName() + ": " + (message == null ? "" : message));
    }
    return null;
  }

  private static String checkState(
      Model model, Map<String, Object> symbols, Value state, Value expected) {
    if (model.abstractState != null) {
      var actual = model.abstractState.apply(symbols, List.of(state));
      if (compareValues(actual, expected) != 0)
        return "the state is " + render(actual) + "; the model is " + render(expected);
    }
    for (int k = 0; k < model.invariants.size(); k++) {
      var kind = model.invariantKinds.get(k);
      var subject = kind.equals("model") ? expected : state;
      if (!truth(model.invariants.get(k).apply(symbols, List.of(subject))))
        return "an invariant on the " + kind + " fails";
    }
    return null;
  }

  private static <T> List<T> replaced(List<T> xs, int at, T x) {
    var out = new ArrayList<T>(xs);
    out.set(at, x);
    return out;
  }

  private static List<ModelRun> shrinkCandidates(Model model, ModelRun run) {
    var out = new ArrayList<ModelRun>();
    var startArgs = run.startArgs();
    var steps = run.steps();
    int n = steps.size();
    for (int size = n / 2; size >= 1; size /= 2) {
      for (int begin = 0; begin < n; begin += size) {
        var kept = new ArrayList<ModelStep>(steps.subList(0, begin));
        kept.addAll(steps.subList(Math.min(begin + size, n), n));
        out.add(new ModelRun(startArgs, kept));
      }
    }
    for (int k = 0; k < n; k++) {
      var s = steps.get(k);
      var command = model.commands.get(s.index());
      int m = Math.min(command.arguments.size(), s.args().size());
      for (int j = 0; j < m; j++)
        for (var c : model.values.shrink(command.arguments.get(j), s.args().get(j)))
          out.add(
              new ModelRun(
                  startArgs, replaced(steps, k, new ModelStep(s.index(), replaced(s.args(), j, c)))));
    }
    int m = Math.min(model.startArguments.size(), startArgs.size());
    for (int j = 0; j < m; j++)
      for (var c : model.values.shrink(model.startArguments.get(j), startArgs.get(j)))
        out.add(new ModelRun(replaced(startArgs, j, c), steps));
    return out;
  }

  private record Shrunk(ModelRun run, ModelFailure failure) {}

  private static Shrunk shrinkRun(Model model, ModelRun run, ModelFailure failure, int budget) {
    while (budget > 0) {
      boolean improved = false;
      for (var candidate : shrinkCandidates(model, run)) {
        budget--;
        if (budget <= 0) {
          improved = true;
          break;
        }
        try {
          simulate(model, new java.util.HashMap<String, Object>(), candidate);
        } catch (InvalidStep e) {
          continue;
        }
        var found = execute(model, candidate);
        if (found != null) {
          run = candidate;
          failure = found;
          improved = true;
          break;
        }
      }
      if (!improved) break;
    }
    return new Shrunk(run, failure);
  }

  private static String renderAll(List<Value> args) {
    var parts = new ArrayList<String>();
    for (var a : args) parts.add(render(a));
    return String.join(", ", parts);
  }

  private static String describeRun(Model model, ModelRun run) {
    var parts = new ArrayList<String>();
    parts.add("start(" + renderAll(run.startArgs()) + ")");
    for (var s : run.steps())
      parts.add(model.commands.get(s.index()).name + "(" + renderAll(s.args()) + ")");
    return String.join("; ", parts);
  }

  /**
   * Checks the system against its model on generated runs; a failure throws
   * AssertionError naming the shortest failing run found.
   */
  public static void checkModel(Model model) {
    String text = System.getenv("LAWSPEC_SEED");
    checkModel(model, 100, 20, 2000, text == null ? 0 : Long.parseUnsignedLong(text.trim()));
  }

  public static void checkModel(Model model, int cases, int maxLength, int maxShrinks, long seed) {
    var random = new SplitMix64(seed);
    for (int c = 0; c < cases; c++) {
      long length = random.below((long) maxLength + 1);
      var run = generateRun(model, random, length, 1 + c % 8);
      var failure = execute(model, run);
      if (failure != null) {
        var shrunk = shrinkRun(model, run, failure, maxShrinks);
        throw new AssertionError(
            "model "
                + model.name
                + " fails at step "
                + shrunk.failure().step()
                + " of "
                + describeRun(model, shrunk.run())
                + ": "
                + shrunk.failure().message());
      }
    }
  }

  // Parallel runs of a shared model. A case is a sequential prefix and one
  // branch per thread, generated so that the model allows every interleaving
  // of the branches (a search over each thread's position and the model
  // state, memoized). The system runs the branches at the same time, each
  // call's start and return recorded on one counter, with random yields and
  // short sleeps around calls to shake out rare schedules. The history must
  // be linearizable: some interleaving that keeps every call after those that
  // returned before it started must give every result the model gives and
  // leave the state it leaves (a Wing-Gong search, memoized on the same
  // positions and model state). Each case runs several times.

  private static final int THREADS = 3;
  private static final int BRANCH = 5;

  private record ParallelCase(ModelRun prefix, List<List<ModelStep>> branches) {}

  /** When a branch's call started and returned, and what it returned. */
  private record Call(long called, long returned, Value result) {}

  private static String searchKey(int[] positions, Value state) {
    return Arrays.toString(positions) + "|" + render(state);
  }

  private static int[] advanced(int[] positions, int i) {
    var next = positions.clone();
    next[i]++;
    return next;
  }

  /** Whether the model allows the prefix then every interleaving. */
  private static boolean parallelAllowed(
      Model model, ModelRun prefix, List<List<ModelStep>> branches) {
    Map<String, Object> symbols = new java.util.HashMap<String, Object>();
    Value state;
    try {
      var states = simulate(model, symbols, prefix);
      state = states.get(states.size() - 1);
    } catch (InvalidStep e) {
      return false;
    }
    return allowedFrom(
        model, symbols, branches, new int[branches.size()], state, new java.util.HashSet<String>());
  }

  private static boolean allowedFrom(
      Model model,
      Map<String, Object> symbols,
      List<List<ModelStep>> branches,
      int[] positions,
      Value state,
      java.util.Set<String> seen) {
    if (!seen.add(searchKey(positions, state))) return true;
    for (int i = 0; i < branches.size(); i++) {
      var branch = branches.get(i);
      int k = positions[i];
      if (k < branch.size()) {
        var s = branch.get(k);
        Value after;
        try {
          after = stepModel(model.commands.get(s.index()), symbols, s.args(), state).state();
        } catch (InvalidStep e) {
          return false;
        }
        if (!allowedFrom(model, symbols, branches, advanced(positions, i), after, seen))
          return false;
      }
    }
    return true;
  }

  private static List<ModelStep> generateBranch(
      Model model, SplitMix64 random, Value state, long length, long size) {
    Map<String, Object> symbols = new java.util.HashMap<String, Object>();
    var steps = new ArrayList<ModelStep>();
    for (long n = 0; n < length; n++) {
      int index = (int) random.below(model.commands.size());
      var command = model.commands.get(index);
      var args = generateAll(model.values, command.arguments, random, size);
      try {
        state = stepModel(command, symbols, args, state).state();
      } catch (InvalidStep e) {
        continue;
      }
      steps.add(new ModelStep(index, args));
    }
    return steps;
  }

  private static ParallelCase generateParallel(
      Model model, SplitMix64 random, long size, int threads, int branchLength) {
    var prefix = generateRun(model, random, random.below(4), size);
    Value state;
    try {
      var states = simulate(model, new java.util.HashMap<String, Object>(), prefix);
      state = states.get(states.size() - 1);
    } catch (InvalidStep e) {
      var empty = new ArrayList<List<ModelStep>>();
      for (int i = 0; i < threads; i++) empty.add(List.of());
      return new ParallelCase(prefix, empty);
    }
    var branches = new ArrayList<List<ModelStep>>();
    for (int i = 0; i < threads; i++)
      branches.add(generateBranch(model, random, state, 1 + random.below(branchLength), size));
    // Drop the last step of the longest branch (the first, among equals)
    // until every interleaving is allowed.
    while (!parallelAllowed(model, prefix, branches)) {
      int longest = 0;
      for (int i = 1; i < threads; i++)
        if (branches.get(i).size() > branches.get(longest).size()) longest = i;
      var b = branches.get(longest);
      branches.set(longest, b.subList(0, Math.max(0, b.size() - 1)));
    }
    return new ParallelCase(prefix, branches);
  }

  /** Nothing, a yield, or a sleep of 10 or 100 microseconds. */
  private static void perturb(SplitMix64 random) {
    long choice = random.below(4);
    if (choice == 1) Thread.yield();
    else if (choice >= 2)
      java.util.concurrent.locks.LockSupport.parkNanos(choice == 2 ? 10_000L : 100_000L);
  }

  private static String raised(Exception e) {
    String message = e.getMessage();
    return "raised " + e.getClass().getSimpleName() + ": " + (message == null ? "" : message);
  }

  private static String branchName(int i) {
    return String.valueOf((char) ('A' + i));
  }

  /** null when the history is linearizable; otherwise what went wrong. */
  private static String executeParallel(Model model, ParallelCase c, long shake) {
    var prefix = c.prefix();
    var branches = c.branches();
    Map<String, Object> symbols = new java.util.HashMap<String, Object>();
    Value started;
    try {
      started = model.startRun.apply(symbols, prefix.startArgs());
      for (var s : prefix.steps()) {
        var command = model.commands.get(s.index());
        var full = new ArrayList<Value>(s.args());
        full.add(command.state, started);
        command.run.apply(symbols, full);
      }
    } catch (Exception e) {
      return "the prefix " + raised(e);
    }
    final Value state = started;
    var clock = new java.util.concurrent.atomic.AtomicLong();
    var history = new ArrayList<Call[]>();
    for (var b : branches) history.add(new Call[b.size()]);
    var errors = Collections.synchronizedList(new ArrayList<String>());
    var ready = new java.util.concurrent.CountDownLatch(1);
    var threads = new ArrayList<Thread>();
    for (int i = 0; i < branches.size(); i++) {
      final int branch = i;
      final var random = new SplitMix64(shake ^ ((long) (i + 1) * 0x9E3779B97F4A7C15L));
      threads.add(
          new Thread(
              () -> {
                Map<String, Object> own = new java.util.HashMap<String, Object>();
                try {
                  ready.await();
                } catch (InterruptedException e) {
                  Thread.currentThread().interrupt();
                }
                var steps = branches.get(branch);
                for (int k = 0; k < steps.size(); k++) {
                  var s = steps.get(k);
                  var command = model.commands.get(s.index());
                  var full = new ArrayList<Value>(s.args());
                  full.add(command.state, state);
                  perturb(random);
                  long called = clock.incrementAndGet();
                  Value result;
                  try {
                    result = command.run.apply(own, full);
                  } catch (Exception e) {
                    errors.add(command.name + " " + raised(e));
                    result = null;
                  }
                  history.get(branch)[k] = new Call(called, clock.incrementAndGet(), result);
                  perturb(random);
                }
              }));
    }
    for (var t : threads) t.start();
    ready.countDown();
    for (var t : threads) {
      boolean interrupted = false;
      while (true) {
        try {
          t.join();
          break;
        } catch (InterruptedException e) {
          interrupted = true;
        }
      }
      if (interrupted) Thread.currentThread().interrupt();
    }
    if (!errors.isEmpty()) return errors.get(0);
    var states = simulate(model, symbols, prefix);
    var expected = states.get(states.size() - 1);
    var finalState =
        model.abstractState != null ? model.abstractState.apply(symbols, List.of(state)) : null;
    if (linearizable(model, symbols, branches, history, expected, finalState, state)) return null;
    var observed = new ArrayList<String>();
    for (int i = 0; i < branches.size(); i++)
      for (int k = 0; k < branches.get(i).size(); k++)
        observed.add(
            branchName(i)
                + ": "
                + model.commands.get(branches.get(i).get(k).index()).name
                + "() returned "
                + render(history.get(i)[k].result()));
    return "no order of the parallel calls agrees with the model ("
        + String.join("; ", observed)
        + ")";
  }

  /**
   * Whether the history linearizes, with the final state and invariants the model gives. For a set
   * or map whose every call touches one key, each key's calls are linearized separately (the keys
   * are independent), one group after another; otherwise all calls at once.
   */
  private static boolean linearizable(
      Model model,
      Map<String, Object> symbols,
      List<List<ModelStep>> branches,
      List<Call[]> history,
      Value expected,
      Value finalState,
      Value state) {
    java.util.function.Predicate<Value> finish =
        modelState -> {
          if (finalState != null && compareValues(finalState, modelState) != 0) return false;
          for (int k = 0; k < model.invariants.size(); k++) {
            var subject = model.invariantKinds.get(k).equals("model") ? modelState : state;
            if (!truth(model.invariants.get(k).apply(symbols, List.of(subject)))) return false;
          }
          return true;
        };
    if (!model.perKey)
      return linearize(
          model,
          symbols,
          branches,
          history,
          new int[branches.size()],
          expected,
          finish,
          new java.util.HashSet<String>());
    // Each key's calls, branch by branch, in order of the rendered key.
    var stepGroups = new java.util.TreeMap<String, List<List<ModelStep>>>();
    var callGroups = new java.util.HashMap<String, List<List<Call>>>();
    for (int i = 0; i < branches.size(); i++) {
      var branch = branches.get(i);
      for (int k = 0; k < branch.size(); k++) {
        var s = branch.get(k);
        String key = render(s.args().get(model.commands.get(s.index()).key));
        if (!stepGroups.containsKey(key)) {
          var steps = new ArrayList<List<ModelStep>>();
          var calls = new ArrayList<List<Call>>();
          for (int j = 0; j < branches.size(); j++) {
            steps.add(new ArrayList<ModelStep>());
            calls.add(new ArrayList<Call>());
          }
          stepGroups.put(key, steps);
          callGroups.put(key, calls);
        }
        stepGroups.get(key).get(i).add(s);
        callGroups.get(key).get(i).add(history.get(i)[k]);
      }
    }
    Value modelState = expected;
    for (var entry : stepGroups.entrySet()) {
      var parts = entry.getValue();
      var calls = new ArrayList<Call[]>();
      for (var c : callGroups.get(entry.getKey())) calls.add(c.toArray(new Call[0]));
      var ends = new ArrayList<Value>();
      if (!linearize(
          model,
          symbols,
          parts,
          calls,
          new int[parts.size()],
          modelState,
          end -> {
            ends.add(end);
            return true;
          },
          new java.util.HashSet<String>())) return false;
      modelState = ends.get(0);
    }
    return finish.test(modelState);
  }

  /**
   * A Wing-Gong search: linearize, next, a call no pending call on another thread returned before;
   * memoized on positions and the model state. finish judges each complete order's final model
   * state.
   */
  private static boolean linearize(
      Model model,
      Map<String, Object> symbols,
      List<List<ModelStep>> branches,
      List<Call[]> history,
      int[] positions,
      Value modelState,
      java.util.function.Predicate<Value> finish,
      java.util.Set<String> seen) {
    if (!seen.add(searchKey(positions, modelState))) return false;
    boolean done = true;
    for (int i = 0; i < branches.size(); i++)
      if (positions[i] != branches.get(i).size()) done = false;
    if (done) return finish.test(modelState);
    for (int i = 0; i < branches.size(); i++) {
      var branch = branches.get(i);
      int k = positions[i];
      if (k == branch.size()) continue;
      long called = history.get(i)[k].called();
      boolean blocked = false;
      for (int j = 0; j < branches.size(); j++)
        if (j != i
            && positions[j] < branches.get(j).size()
            && history.get(j)[positions[j]].returned() < called) blocked = true;
      if (blocked) continue;
      var s = branch.get(k);
      var command = model.commands.get(s.index());
      Stepped stepped;
      try {
        stepped = stepModel(command, symbols, s.args(), modelState);
      } catch (InvalidStep e) {
        continue;
      }
      if (!command.unit && compareValues(history.get(i)[k].result(), stepped.result()) != 0)
        continue;
      if (linearize(
          model,
          symbols,
          branches,
          history,
          advanced(positions, i),
          stepped.state(),
          finish,
          seen)) return true;
    }
    return false;
  }

  private static String parallelFails(Model model, ParallelCase c, int repeats, long shake) {
    for (int attempt = 0; attempt < repeats; attempt++) {
      var failure = executeParallel(model, c, shake + attempt);
      if (failure != null) return failure;
    }
    return null;
  }

  private static <T> List<T> without(List<T> xs, int at) {
    var out = new ArrayList<T>(xs.subList(0, at));
    out.addAll(xs.subList(at + 1, xs.size()));
    return out;
  }

  private record ShrunkParallel(ParallelCase c, String failure) {}

  private static ShrunkParallel shrinkParallel(
      Model model, ParallelCase c, String failure, int repeats, int budget, long shake) {
    while (budget > 0) {
      var prefix = c.prefix();
      var branches = c.branches();
      var candidates = new ArrayList<ParallelCase>();
      var steps = prefix.steps();
      for (int k = 0; k < steps.size(); k++)
        candidates.add(
            new ParallelCase(new ModelRun(prefix.startArgs(), without(steps, k)), branches));
      for (int i = 0; i < branches.size(); i++)
        for (int k = 0; k < branches.get(i).size(); k++) {
          var shorter = new ArrayList<List<ModelStep>>(branches);
          shorter.set(i, without(branches.get(i), k));
          candidates.add(new ParallelCase(prefix, shorter));
        }
      // Then smaller arguments, branch by branch, step by step.
      for (int i = 0; i < branches.size(); i++)
        for (int k = 0; k < branches.get(i).size(); k++) {
          var s = branches.get(i).get(k);
          var command = model.commands.get(s.index());
          int m = Math.min(command.arguments.size(), s.args().size());
          for (int a = 0; a < m; a++)
            for (var smaller : model.values.shrink(command.arguments.get(a), s.args().get(a))) {
              var changed = new ArrayList<List<ModelStep>>(branches);
              var step = new ModelStep(s.index(), replaced(s.args(), a, smaller));
              changed.set(i, replaced(branches.get(i), k, step));
              candidates.add(new ParallelCase(prefix, changed));
            }
        }
      boolean improved = false;
      for (var candidate : candidates) {
        budget--;
        if (budget <= 0) {
          improved = true;
          break;
        }
        if (!parallelAllowed(model, candidate.prefix(), candidate.branches())) continue;
        var found = parallelFails(model, candidate, repeats, shake);
        if (found != null) {
          c = candidate;
          failure = found;
          improved = true;
          break;
        }
      }
      if (!improved) break;
    }
    return new ShrunkParallel(c, failure);
  }

  private static String describeBranch(Model model, List<ModelStep> steps) {
    var parts = new ArrayList<String>();
    for (var s : steps)
      parts.add(model.commands.get(s.index()).name + "(" + renderAll(s.args()) + ")");
    return parts.isEmpty() ? "nothing" : String.join("; ", parts);
  }

  private static String describeParallel(Model model, ParallelCase c) {
    var parts = new ArrayList<String>();
    var branches = c.branches();
    for (int i = 0; i < branches.size(); i++)
      parts.add(branchName(i) + ": " + describeBranch(model, branches.get(i)));
    return describeRun(model, c.prefix())
        + ", then "
        + String.join(", ", parts.subList(0, parts.size() - 1))
        + " and "
        + parts.get(parts.size() - 1)
        + " at the same time";
  }

  /**
   * Checks a shared model's histories under concurrency; a failure throws
   * AssertionError naming the smallest failing case found.
   */
  public static void checkModelParallel(Model model) {
    String text = System.getenv("LAWSPEC_SEED");
    checkModelParallel(
        model, 50, 10, 300, text == null ? 0 : Long.parseUnsignedLong(text.trim()), THREADS, BRANCH);
  }

  public static void checkModelParallel(
      Model model, int cases, int repeats, int maxShrinks, long seed) {
    checkModelParallel(model, cases, repeats, maxShrinks, seed, THREADS, BRANCH);
  }

  public static void checkModelParallel(
      Model model,
      int cases,
      int repeats,
      int maxShrinks,
      long seed,
      int threads,
      int branchLength) {
    var random = new SplitMix64(seed ^ 0x5BD1E995L);
    for (int n = 0; n < cases; n++) {
      var c = generateParallel(model, random, 1 + n % 8, threads, branchLength);
      long shake = random.next();
      var failure = parallelFails(model, c, repeats, shake);
      if (failure != null) {
        var shrunk =
            shrinkParallel(model, c, failure, Math.max(2, repeats / 2), maxShrinks, shake);
        throw new AssertionError(
            "model "
                + model.name
                + " is not linearizable: "
                + describeParallel(model, shrunk.c())
                + ": "
                + shrunk.failure());
      }
    }
  }
}
