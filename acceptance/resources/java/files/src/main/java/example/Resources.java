// User-owned LawSpec adapters for the resources example.
package example;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;
import lawspec.runtime.LawSpecRuntime;
import lawspec.runtime.LawSpecRuntime.Value;

public final class Resources {
  /** An in-memory store. At most three may be open at once, so a store that
   * is never closed is noticed. */
  static final class Store {
    static int openCount = 0;
    Map<Integer, Integer> items = new HashMap<>();
    boolean open = true;

    Store() {
      if (openCount >= 3) throw new IllegalStateException("too many open stores: one was never closed");
      openCount++;
    }

    void close() {
      if (open) {
        open = false;
        openCount--;
      }
    }
  }

  // (Unit -> example.resources::type::Store)
  public static java.lang.Object openStore(Value value0) {
    return new Store();
  }

  // (example.resources::type::Store -> Unit)
  public static void closeStore(java.lang.Object value0) {
    ((Store) value0).close();
  }

  // (example.resources::type::Store -> Unit)
  public static void clearStore(java.lang.Object value0) {
    ((Store) value0).items.clear();
  }

  // (example.resources::type::Store -> (Int32 -> (Int32 -> Unit)))
  public static void put(java.lang.Object value0, int value1, int value2) {
    Store store = (Store) value0;
    if (!store.open) throw new IllegalStateException("the store is closed");
    store.items.put(value1, value2);
  }

  // (example.resources::type::Store -> (Int32 -> Maybe (Int32)))
  public static LawSpecRuntime.Maybe<java.lang.Integer> get(java.lang.Object value0, int value1) {
    Store store = (Store) value0;
    if (!store.open) throw new IllegalStateException("the store is closed");
    Integer value = store.items.get(value1);
    return value == null ? new LawSpecRuntime.Nothing<>() : new LawSpecRuntime.Just<>(value);
  }

  // (example.resources::type::Store -> Bool)
  public static boolean isOpen(java.lang.Object value0) {
    return ((Store) value0).open;
  }

  // (example.resources::type::Store -> Int32)
  public static int size(java.lang.Object value0) {
    return ((Store) value0).items.size();
  }

  // (Text -> (Int32 -> Unit))
  public static void writeNote(String value0, int value1) {
    try {
      Files.writeString(Path.of(value0, "note.txt"), Integer.toString(value1));
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }

  // (Text -> Maybe (Int32))
  public static LawSpecRuntime.Maybe<java.lang.Integer> readNote(String value0) {
    Path note = Path.of(value0, "note.txt");
    if (!Files.exists(note)) return new LawSpecRuntime.Nothing<>();
    try {
      return new LawSpecRuntime.Just<>(Integer.parseInt(Files.readString(note)));
    } catch (IOException e) {
      throw new UncheckedIOException(e);
    }
  }

  // (Int32 -> Bool)
  public static boolean canListen(int value0) {
    try (ServerSocket socket = new ServerSocket(value0, 1, InetAddress.getLoopbackAddress())) {
      return true;
    } catch (IOException e) {
      return false;
    }
  }

  // (Int32 -> Unit)
  public static void setGreeting(int value0) {
    System.setProperty("lawspec.example.greeting", Integer.toString(value0));
  }

  // (Unit -> Maybe (Int32))
  public static LawSpecRuntime.Maybe<java.lang.Integer> greeting(Value value0) {
    String value = System.getProperty("lawspec.example.greeting");
    return value == null ? new LawSpecRuntime.Nothing<>() : new LawSpecRuntime.Just<>(Integer.parseInt(value));
  }
}
