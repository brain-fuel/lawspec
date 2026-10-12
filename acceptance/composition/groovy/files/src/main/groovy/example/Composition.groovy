// User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
// share the case's Store.
package example

import java.util.ArrayList
import java.util.HashMap
import java.util.List
import java.util.Map
import lawspec.runtime.LawSpecRuntime
import lawspec.runtime.LawSpecRuntime.Value

@groovy.transform.CompileStatic
final class Composition {
  /** An in-memory log store: each log's records, newest last. */
  static final class LogStore {
    final Map<String, List<String>> logs = new HashMap<>()
    boolean open = true
  }

  // (Unit -> example.composition::type::Store)
  static Object openStore(Value value0) {
    return new LogStore()
  }

  // (example.composition::type::Store -> Unit)
  static void closeStore(Object value0) {
    ((LogStore) value0).open = false
  }

  /** The native handler of Logs: create, append. */
  static final class LogsHandler implements lawspec.abilities.example.Composition.Logs {
    final Object resource

    LogsHandler(Object resource) {
      this.resource = resource
    }

    @Override
    void create(String value0) {
      ((LogStore) resource).logs.put(value0, new ArrayList<>())
    }

    @Override
    Long append(String value0, String value1) {
      List<String> records = ((LogStore) resource).logs.get(value0)
      if (records == null) throw new LawSpecRuntime.Fail(new lawspec.data.Problem.UnknownLog())
      if (value1.isEmpty()) throw new LawSpecRuntime.Fail(new lawspec.data.Problem.EmptyRecord())
      records.add(value1)
      return (long) (records.size() - 1)
    }
  }

  /** The native handler of Reader: size. */
  static final class ReaderHandler implements lawspec.abilities.example.Composition.Reader {
    final Object resource

    ReaderHandler(Object resource) {
      this.resource = resource
    }

    @Override
    lawspec.runtime.LawSpecRuntime.Maybe<Long> size(String value0) {
      List<String> records = ((LogStore) resource).logs.get(value0)
      if (records == null) return new LawSpecRuntime.Nothing<>()
      return new LawSpecRuntime.Just<>((long) records.size())
    }
  }

  /** The native handler of Writer: write, lastOffset. */
  static final class WriterHandler implements lawspec.abilities.example.Composition.Writer {
    final Object resource
    private lawspec.runtime.LawSpecRuntime.Maybe<Long> last = new lawspec.runtime.LawSpecRuntime.Nothing<>()

    WriterHandler(Object resource) {
      this.resource = resource
    }

    @Override
    Boolean write(String value0, String value1) {
      List<String> records = ((LogStore) resource).logs.get(value0)
      if (records == null || value1.isEmpty()) return false
      records.add(value1)
      last = new LawSpecRuntime.Just<>((long) (records.size() - 1))
      return true
    }

    @Override
    lawspec.runtime.LawSpecRuntime.Maybe<Long> lastOffset() {
      return last
    }
  }
}
