// User-owned LawSpec adapter: a page-view counter with one replica per thread.
package example

import lawspec.data.Views
import scala.collection.mutable

object Consistency {
  private val replicas = mutable.HashMap[Int, mutable.HashMap[Long, Long]]()
  private var ids = 0

  // (Unit -> example.consistency::type::Views)
  def newViews(value0: scala.Unit): lawspec.data.Views = synchronized {
    val id = ids
    ids += 1
    replicas(id) = mutable.HashMap()
    Views(id)
  }

  // (example.consistency::type::Views -> Int64)
  def hit(value0: lawspec.data.Views): scala.Long = synchronized {
    val mine = replicas(value0.id)
    val me = Thread.currentThread().threadId()
    val next = mine.getOrElse(me, 0L) + 1
    mine(me) = next
    next
  }

  // (example.consistency::type::Views -> Int64)
  def total(value0: lawspec.data.Views): scala.Long = synchronized {
    replicas(value0.id).values.sum
  }
}
