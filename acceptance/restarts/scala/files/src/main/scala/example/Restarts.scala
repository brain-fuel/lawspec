// User-owned LawSpec adapter: a tab's handlers, run inside an actor.
package example

import lawspec.actors.BarSupervisor
import lawspec.data.{Pair, Tab}

object Restarts {
  // (Unit -> example.restarts::type::Tab)
  def openTab(value0: scala.Unit): lawspec.data.Tab = Tab(0)

  // (example.restarts::type::Tab -> (UInt8 -> lawspec.collections::type::Pair (Int64)
  // (example.restarts::type::Tab)))
  def add(
    value0: lawspec.data.Tab,
    value1: scala.Short,
  ): lawspec.data.Pair[scala.Long, lawspec.data.Tab] = {
    val after = value0.total + value1
    Pair(after, Tab(after))
  }

  // (example.restarts::type::Tab -> lawspec.collections::type::Pair (Int64)
  // (example.restarts::type::Tab))
  def total(value0: lawspec.data.Tab): lawspec.data.Pair[scala.Long, lawspec.data.Tab] =
    Pair(value0.total, value0)

  // (UInt8 -> Int64)
  def keepsTotal(value0: scala.Short): scala.Long = {
    val bar = BarSupervisor.start()
    bar.tab.add(value0)
    bar.tab.crash()
    val total = bar.tab.total()
    bar.stop()
    total
  }
}
