// User-owned LawSpec adapter: a queue, a set and a map shared between
// threads, each one of the JVM's own concurrent structures.
package example

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import lawspec.data.Cache
import lawspec.data.Tags
import lawspec.data.WorkQueue
import lawspec.runtime.LawSpecRuntime

object Concurrent {
    private val ids = AtomicInteger()
    private val queues = ConcurrentHashMap<Int, ConcurrentLinkedQueue<Int>>()
    private val sets = ConcurrentHashMap<Int, MutableSet<Int>>()
    private val maps = ConcurrentHashMap<Int, ConcurrentHashMap<Byte, Long>>()

    // A structure by its handle; generated tests may name one first.
    private fun queue(handle: WorkQueue): ConcurrentLinkedQueue<Int> =
        queues.computeIfAbsent(handle.id) { ConcurrentLinkedQueue() }

    private fun set(handle: Tags): MutableSet<Int> =
        sets.computeIfAbsent(handle.id) { ConcurrentHashMap.newKeySet() }

    private fun map(handle: Cache): ConcurrentHashMap<Byte, Long> =
        maps.computeIfAbsent(handle.id) { ConcurrentHashMap() }

    private fun <T> maybe(value: T?): LawSpecRuntime.Maybe<T> =
        if (value == null) LawSpecRuntime.Nothing() else LawSpecRuntime.Just(value)

    fun newQueue(value0: Unit): WorkQueue {
        val handle = WorkQueue(ids.incrementAndGet())
        queue(handle)
        return handle
    }

    suspend fun offer(value0: WorkQueue, value1: Int) {
        queue(value0).offer(value1)
    }

    suspend fun poll(value0: WorkQueue): LawSpecRuntime.Maybe<Int> {
        val q = queue(value0)
        return maybe(q.poll())
    }

    suspend fun queueSize(value0: WorkQueue): Long = queue(value0).size.toLong()

    fun newTags(value0: Unit): Tags {
        val handle = Tags(ids.incrementAndGet())
        set(handle)
        return handle
    }

    suspend fun tag(value0: Tags, value1: Int): Boolean = set(value0).add(value1)

    suspend fun untag(value0: Tags, value1: Int): Boolean = set(value0).remove(value1)

    suspend fun tagged(value0: Tags, value1: Int): Boolean = set(value0).contains(value1)

    fun newCache(value0: Unit): Cache {
        val handle = Cache(ids.incrementAndGet())
        map(handle)
        return handle
    }

    suspend fun store(value0: Cache, value1: Byte, value2: Long): LawSpecRuntime.Maybe<Long> =
        maybe(map(value0).put(value1, value2))

    suspend fun fetch(value0: Cache, value1: Byte): LawSpecRuntime.Maybe<Long> =
        maybe(map(value0)[value1])

    suspend fun evict(value0: Cache, value1: Byte): LawSpecRuntime.Maybe<Long> =
        maybe(map(value0).remove(value1))
}
