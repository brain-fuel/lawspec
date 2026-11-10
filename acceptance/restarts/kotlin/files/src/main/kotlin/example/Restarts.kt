// User-owned LawSpec adapter: a tab's handlers, run inside an actor.
package example

import lawspec.actors.BarSupervisor
import lawspec.data.Pair
import lawspec.data.Tab

object Restarts {
    fun openTab(value0: Unit): Tab = Tab(0)

    fun add(value0: Tab, value1: Short): Pair<Long, Tab> {
        val after = value0.total + value1
        return Pair(after, Tab(after))
    }

    fun total(value0: Tab): Pair<Long, Tab> = Pair(value0.total, value0)

    fun keepsTotal(value0: Short): Long {
        val bar = BarSupervisor.start()
        bar.tab.add(value0)
        bar.tab.crash()
        val total = bar.tab.total()
        bar.stop()
        return total
    }
}
