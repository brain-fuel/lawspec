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

    fun push(value0: Byte, value1: Stack): PushFlow = PushFlow(Stack.Push(lawspec.data.Recordd055baeeed41ba47fc1e56412cb39424d62fb8f1a3afa343166abc5bf09d2949(value1, value0)))

    // The flow signature guarantees a nonempty stack.
    fun pop(value0: Stack): PopFlow {
        val cell = value0 as Stack.Push
        return PopFlow(cell.value.top, cell.value.rest)
    }

    fun peek(value0: Stack): PeekFlow {
        val cell = value0 as Stack.Push
        return PeekFlow(cell.value.top, cell)
    }

    fun newCounter(value0: Unit): Counter {
        val id = ids.incrementAndGet()
        counters[id] = AtomicLong()
        return Counter(id)
    }

    suspend fun increment(value0: Counter): Long = counters.getValue(value0.id).incrementAndGet()

    suspend fun decrement(value0: Counter): Long = counters.getValue(value0.id).decrementAndGet()

    suspend fun read(value0: Counter): Long = counters.getValue(value0.id).get()
}
