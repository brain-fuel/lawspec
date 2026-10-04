// User-owned LawSpec adapter: a stack and an atomic counter.
package example

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import lawspec.data.Counter
import lawspec.data.PeekFlow
import lawspec.data.PopFlow
import lawspec.data.PushFlow
import lawspec.data.Stack

object Models {
    private val counters = ConcurrentHashMap<Int, AtomicLong>()
    private val ids = AtomicInteger()

    fun empty(value0: Unit): Stack = Stack.Empty

    fun push(value0: Byte, value1: Stack): PushFlow = PushFlow(Stack.Push(value0, value1))

    // The flow signature guarantees a nonempty stack.
    fun pop(value0: Stack): PopFlow {
        val cell = value0 as Stack.Push
        return PopFlow(cell.top, cell.rest)
    }

    fun peek(value0: Stack): PeekFlow {
        val cell = value0 as Stack.Push
        return PeekFlow(cell.top, cell)
    }

    fun newCounter(value0: Unit): Counter {
        val id = ids.incrementAndGet()
        counters[id] = AtomicLong()
        return Counter(id)
    }

    fun increment(value0: Counter): Long = counters.getValue(value0.id).incrementAndGet()

    fun decrement(value0: Counter): Long = counters.getValue(value0.id).decrementAndGet()

    fun read(value0: Counter): Long = counters.getValue(value0.id).get()
}
