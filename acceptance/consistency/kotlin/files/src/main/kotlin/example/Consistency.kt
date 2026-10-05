// User-owned LawSpec adapter: a page-view counter with one replica per thread.
package example

import lawspec.data.Views
import lawspec.runtime.LawSpecRuntime

object Consistency {
    private val replicas = HashMap<Int, HashMap<Long, Long>>()
    private var ids = 0

    @Synchronized
    fun newViews(value0: Unit): Views {
        val id = ids++
        replicas[id] = HashMap()
        return Views(id)
    }

    @Synchronized
    fun hit(value0: Views): Long {
        val mine = replicas.getValue(value0.id)
        val me = Thread.currentThread().threadId()
        val next = (mine[me] ?: 0L) + 1
        mine[me] = next
        return next
    }

    @Synchronized
    fun total(value0: Views): Long = replicas.getValue(value0.id).values.sum()
}
