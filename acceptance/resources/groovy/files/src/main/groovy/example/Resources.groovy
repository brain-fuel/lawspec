// User-owned LawSpec adapters for the resources example.
package example

import java.io.IOException
import java.io.UncheckedIOException
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.file.Files
import java.nio.file.Path
import java.util.HashMap
import java.util.Map
import lawspec.runtime.LawSpecRuntime
import lawspec.runtime.LawSpecRuntime.Value

@groovy.transform.CompileStatic
final class Resources {
  /** An in-memory store. At most three may be open at once, so a store that
   * is never closed is noticed. */
  static final class Store {
    static int openCount = 0
    Map<Integer, Integer> items = new HashMap<>()
    boolean open = true

    Store() {
      if (openCount >= 3) throw new IllegalStateException('too many open stores: one was never closed')
      openCount++
    }

    void close() {
      if (open) {
        open = false
        openCount--
      }
    }
  }

  // (Unit -> example.resources::type::Store)
  static Object openStore(Value value0) {
    return new Store()
  }

  // (example.resources::type::Store -> Unit)
  static void closeStore(Object value0) {
    ((Store) value0).close()
  }

  // (example.resources::type::Store -> Unit)
  static void clearStore(Object value0) {
    ((Store) value0).items.clear()
  }

  // (example.resources::type::Store -> (Int32 -> (Int32 -> Unit)))
  static void put(Object value0, int value1, int value2) {
    Store store = (Store) value0
    if (!store.open) throw new IllegalStateException('the store is closed')
    store.items.put(value1, value2)
  }

  // (example.resources::type::Store -> (Int32 -> Maybe (Int32)))
  static lawspec.runtime.LawSpecRuntime.Maybe<Integer> get(Object value0, int value1) {
    Store store = (Store) value0
    if (!store.open) throw new IllegalStateException('the store is closed')
    Integer value = store.items.get(value1)
    return value == null ? new LawSpecRuntime.Nothing<>() : new LawSpecRuntime.Just<>(value)
  }

  // (example.resources::type::Store -> Bool)
  static boolean isOpen(Object value0) {
    return ((Store) value0).open
  }

  // (example.resources::type::Store -> Int32)
  static int size(Object value0) {
    return ((Store) value0).items.size()
  }

  // (Text -> (Int32 -> Unit))
  static void writeNote(String value0, int value1) {
    try {
      Files.writeString(Path.of(value0, 'note.txt'), Integer.toString(value1))
    } catch (IOException e) {
      throw new UncheckedIOException(e)
    }
  }

  // (Text -> Maybe (Int32))
  static lawspec.runtime.LawSpecRuntime.Maybe<Integer> readNote(String value0) {
    Path note = Path.of(value0, 'note.txt')
    if (!Files.exists(note)) return new LawSpecRuntime.Nothing<>()
    try {
      return new LawSpecRuntime.Just<>(Integer.parseInt(Files.readString(note)))
    } catch (IOException e) {
      throw new UncheckedIOException(e)
    }
  }

  // (Int32 -> Bool)
  static boolean canListen(int value0) {
    try (ServerSocket socket = new ServerSocket(value0, 1, InetAddress.getLoopbackAddress())) {
      return true
    } catch (IOException e) {
      return false
    }
  }

  // (Int32 -> Unit)
  static void setGreeting(int value0) {
    System.setProperty('lawspec.example.greeting', Integer.toString(value0))
  }

  // (Unit -> Maybe (Int32))
  static lawspec.runtime.LawSpecRuntime.Maybe<Integer> greeting(Value value0) {
    String value = System.getProperty('lawspec.example.greeting')
    return value == null ? new LawSpecRuntime.Nothing<>() : new LawSpecRuntime.Just<>(Integer.parseInt(value))
  }

  // A pool that is costly to open: this JVM may open only one, so the suite
  // passes only if the harness shares it (share Pool per unit).
  static final class Pool {
    static int opened = 0
    int amount = 0
    boolean open = true

    Pool() {
      if (opened >= 1) throw new IllegalStateException('a second pool was opened: the harness should share it')
      opened++
    }
  }

  // (Unit -> example.resources::type::Pool)
  static Object openPool(Value value0) {
    return new Pool()
  }

  // (example.resources::type::Pool -> Unit)
  static void drainPool(Object value0) {
    ((Pool) value0).amount = 0
  }

  // (example.resources::type::Pool -> Unit)
  static void closePool(Object value0) {
    ((Pool) value0).open = false
  }

  // (example.resources::type::Pool -> (Int32 -> Unit))
  static void fill(Object value0, int value1) {
    Pool pool = (Pool) value0
    if (!pool.open) throw new IllegalStateException('the pool is closed')
    pool.amount += value1
  }

  // (example.resources::type::Pool -> Int32)
  static int level(Object value0) {
    return ((Pool) value0).amount
  }
}
