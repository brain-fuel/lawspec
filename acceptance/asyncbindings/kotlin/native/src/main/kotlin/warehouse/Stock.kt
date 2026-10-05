package warehouse

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.yield

// Application code the warehouse adapters are bound to: some of it
// asynchronous, as a real service client would be.
object Stock {
    private fun price(sku: String): Int = if (sku == "free") 0 else sku.codePointCount(0, sku.length) % 100

    suspend fun priceOf(sku: String): Int {
        yield()
        return price(sku)
    }

    fun quoteOf(sku: String): Int = price(sku)

    // A stock count that several callers may change.
    class Shelf {
        private val lock = Mutex()
        private var total = 0L

        suspend fun restock(amount: Int) {
            lock.withLock {
                total += amount
            }
        }

        suspend fun count(): Long = lock.withLock { total }
    }
}
