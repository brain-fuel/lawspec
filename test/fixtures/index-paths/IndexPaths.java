import java.util.List;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Value;
import lawspec.runtime.LawSpecSchema;
import lawspec.runtime.LawSpecSchema.*;

public class IndexPaths {
  static Named chain = new Named("Chain", List.of());
  static Named inner = new Named("lawspec::structural::record::inner", List.of());
  static Named outer = new Named("lawspec::structural::record::outer", List.of());
  static Named wrapper = new Named("Wrapper", List.of());
  static Constructor ctor(String tag, List<Field> fields, String... indices) {
    return new Constructor(tag, fields, List.of(), List.of(indices));
  }
  static Value value(String type, String tag, Value... fields) {
    return new Value(type, new LawSpecRuntime.Data(tag, List.of(fields)));
  }
  static Value wrap(Value left, Value right) {
    return value("Wrapper", "Wrap", value(outer.name(), "Outer", value(inner.name(), "Inner", left), right));
  }
  static LawSpecSchema schema(String path) {
    return new LawSpecSchema(List.of(
      new Definition("Chain", 0, List.of(ctor("Stop", List.of(), "c0", "c10"),
        ctor("Next", List.of(new Field("tail", chain)), "+ f0 c1", "+ f0.1 c1"))),
      new Definition(inner.name(), 0, List.of(ctor("Inner", List.of(new Field("rest", chain))))),
      new Definition(outer.name(), 0, List.of(ctor("Outer", List.of(new Field("child", inner), new Field("sibling", chain)), "== p0/0.0 f1"))),
      new Definition("Wrapper", 0, List.of(ctor("Wrap", List.of(new Field("payload", outer)),
        path, "p0/0/0.1", "== p0/0/0.1 + p0/1.0 c10", "== " + path + " p0/1.0", ">= " + path + " c1")))
    ));
  }
  public static void main(String[] args) {
    var schema = schema("p0/0/0.0");
    var stop = value("Chain", "Stop");
    var one = value("Chain", "Next", stop);
    var two = value("Chain", "Next", one);
    for (int bits : new int[]{32,64}) {
      schema.validate(wrapper, wrap(two,two), bits);
      schema.validate(outer, value(outer.name(), "Outer", value(inner.name(), "Inner", two), two), bits);
      boolean invalidProduct = false;
      try { schema.validate(outer, value(outer.name(), "Outer", value(inner.name(), "Inner", two), stop), bits); }
      catch (RefinementViolation expected) { invalidProduct = true; }
      if (!invalidProduct) throw new AssertionError("accepted invalid intrinsic record guard without parent");
      for (var path : List.of("f0/0/0.0", "p0/0/0.0.0", "p0/1/0.0", "p0/9.0")) {
        boolean rejected = false;
        try { schema(path).validate(wrapper, wrap(two,two), bits); }
        catch (IllegalArgumentException | IndexOutOfBoundsException expected) { rejected = true; }
        if (!rejected) throw new AssertionError("accepted malformed or nominal index path");
      }
      for (var bad : List.of(wrap(two,one), wrap(stop,stop))) {
        boolean rejected = false;
        try { schema.validate(wrapper, bad, bits); }
        catch (RefinementViolation expected) { rejected = true; }
        if (!rejected) throw new AssertionError("accepted mismatched or underflowing indices");
      }
    }
    System.out.println("index path conformance: JVM, both widths");
  }
}
