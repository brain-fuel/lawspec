// User-owned LawSpec adapter: a stack and an atomic counter.
package example

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.{AtomicInteger, AtomicLong}
import lawspec.data.{Counter, PeekFlow, PopFlow, PushFlow, Stack}
import scala.concurrent.Future

object Models {
  private val counters = ConcurrentHashMap[Int, AtomicLong]()
  private val ids = AtomicInteger()

  // (Unit -> example.models::type::Stack)
  def empty(value0: scala.Unit): lawspec.data.Stack = Stack.Empty

  // (Int8 -> (example.models::type::Stack -> example.models::type::PushFlow))
  def push(value0: scala.Byte, value1: lawspec.data.Stack): lawspec.data.PushFlow =
    PushFlow(Stack.Push(lawspec.data.Recordd055baeeed41ba47fc1e56412cb39424d62fb8f1a3afa343166abc5bf09d2949(value1, value0)))

  // The flow signature guarantees a nonempty stack.
  // (example.models::type::Stack -> example.models::type::PopFlow)
  def pop(value0: lawspec.data.Stack): lawspec.data.PopFlow = {
    val cell = value0.asInstanceOf[Stack.Push]
    PopFlow(cell.value.top, cell.value.rest)
  }

  // (example.models::type::Stack -> example.models::type::PeekFlow)
  def peek(value0: lawspec.data.Stack): lawspec.data.PeekFlow = {
    val cell = value0.asInstanceOf[Stack.Push]
    PeekFlow(cell.value.top, cell)
  }

  // (Unit -> example.models::type::Counter)
  def newCounter(value0: scala.Unit): lawspec.data.Counter = {
    val id = ids.incrementAndGet()
    counters.put(id, AtomicLong())
    Counter(id)
  }

  // (example.models::type::Counter -> Int64)
  def increment(value0: lawspec.data.Counter): scala.concurrent.Future[scala.Long] =
    Future.successful(counters.get(value0.id).incrementAndGet())

  // (example.models::type::Counter -> Int64)
  def decrement(value0: lawspec.data.Counter): scala.concurrent.Future[scala.Long] =
    Future.successful(counters.get(value0.id).decrementAndGet())

  // (example.models::type::Counter -> Int64)
  def read(value0: lawspec.data.Counter): scala.concurrent.Future[scala.Long] =
    Future.successful(counters.get(value0.id).get())
}
