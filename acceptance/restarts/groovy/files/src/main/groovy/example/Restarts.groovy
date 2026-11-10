// User-owned LawSpec adapter: a tab's handlers, run inside an actor.
package example

import lawspec.actors.BarSupervisor
import lawspec.data.Pair
import lawspec.data.Tab
import lawspec.runtime.LawSpecRuntime.Value

@groovy.transform.CompileStatic
final class Restarts {
  static Tab openTab(Value value0) {
    return new Tab(0L)
  }

  static Pair<Long, Tab> add(Tab value0, short value1) {
    long after = value0.total() + value1
    return new Pair<>(after, new Tab(after))
  }

  static Pair<Long, Tab> total(Tab value0) {
    return new Pair<>(value0.total(), value0)
  }

  static long keepsTotal(short value0) {
    var bar = BarSupervisor.start()
    bar.tab.add(value0)
    bar.tab.crash()
    long total = bar.tab.total()
    bar.stop()
    return total
  }
}
