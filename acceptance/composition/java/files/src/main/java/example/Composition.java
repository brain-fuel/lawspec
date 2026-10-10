// User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
// share the case's Store.
package example;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Value;

public final class Composition {
  /** An in-memory log store: each log's records, newest last. */
  static final class LogStore {
    final Map<String, List<String>> logs = new HashMap<>();
    boolean open = true;
  }

  // (Unit -> example.composition::type::Store)
  public static java.lang.Object openStore(Value value0) {
    return new LogStore();
  }

  // (example.composition::type::Store -> Unit)
  public static void closeStore(java.lang.Object value0) {
    ((LogStore) value0).open = false;
  }

  /** The native handler of Logs: create, append. */
  public static final class LogsHandler implements lawspec.abilities.example.Composition.Logs {
    public final java.lang.Object resource;

    public LogsHandler(java.lang.Object resource) {
      this.resource = resource;
    }

    @Override
    public void create(java.lang.String value0) {
      ((LogStore) resource).logs.put(value0, new ArrayList<>());
    }

    @Override
    public java.lang.Long append(java.lang.String value0, java.lang.String value1) {
      List<String> records = ((LogStore) resource).logs.get(value0);
      if (records == null) throw new LawSpecRuntime.Fail(new lawspec.data.Problem.UnknownLog());
      if (value1.isEmpty()) throw new LawSpecRuntime.Fail(new lawspec.data.Problem.EmptyRecord());
      records.add(value1);
      return (long) (records.size() - 1);
    }
  }

  /** The native handler of Reader: size. */
  public static final class ReaderHandler implements lawspec.abilities.example.Composition.Reader {
    public final java.lang.Object resource;

    public ReaderHandler(java.lang.Object resource) {
      this.resource = resource;
    }

    @Override
    public lawspec.runtime.LawSpecRuntime.Maybe<java.lang.Long> size(java.lang.String value0) {
      List<String> records = ((LogStore) resource).logs.get(value0);
      if (records == null) return new LawSpecRuntime.Nothing<>();
      return new LawSpecRuntime.Just<>((long) records.size());
    }
  }

  /** The native handler of Writer: write, lastOffset. */
  public static final class WriterHandler implements lawspec.abilities.example.Composition.Writer {
    public final java.lang.Object resource;
    private LawSpecRuntime.Maybe<java.lang.Long> last = new LawSpecRuntime.Nothing<>();

    public WriterHandler(java.lang.Object resource) {
      this.resource = resource;
    }

    @Override
    public java.lang.Boolean write(java.lang.String value0, java.lang.String value1) {
      List<String> records = ((LogStore) resource).logs.get(value0);
      if (records == null || value1.isEmpty()) return false;
      records.add(value1);
      last = new LawSpecRuntime.Just<>((long) (records.size() - 1));
      return true;
    }

    @Override
    public lawspec.runtime.LawSpecRuntime.Maybe<java.lang.Long> lastOffset() {
      return last;
    }
  }
}
