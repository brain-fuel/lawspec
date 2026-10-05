// User-owned LawSpec adapter: a page-view counter with one replica per thread.
package example;

import java.util.HashMap;
import java.util.Map;
import lawspec.data.Views;
import lawspec.runtime.LawSpecRuntime;

public final class Consistency {
  private static final Map<Integer, Map<Long, Long>> replicas = new HashMap<>();
  private static int ids;

  public static synchronized Views newViews(LawSpecRuntime.Value value0) {
    int id = ids++;
    replicas.put(id, new HashMap<>());
    return new Views(id);
  }

  public static synchronized long hit(Views value0) {
    var mine = replicas.get(value0.id());
    long me = Thread.currentThread().threadId();
    return mine.merge(me, 1L, Long::sum);
  }

  public static synchronized long total(Views value0) {
    long sum = 0;
    for (long n : replicas.get(value0.id()).values()) sum += n;
    return sum;
  }
}
