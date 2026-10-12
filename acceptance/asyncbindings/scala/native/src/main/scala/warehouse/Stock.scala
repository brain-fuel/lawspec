package warehouse

import scala.concurrent.{ExecutionContext, Future}

// Application code the warehouse adapters are bound to: some of it
// asynchronous, as a real service client would be.
object Stock {
  private given ExecutionContext = ExecutionContext.global

  private def price(sku: String): Int = if (sku == "free") 0 else sku.codePointCount(0, sku.length) % 100

  def priceOf(sku: String): Future[Int] = Future {
    price(sku)
  }

  def quoteOf(sku: String): Int = price(sku)

  // A stock count that several callers may change.
  class Shelf {
    private var total = 0L

    def restock(amount: Int): Future[Unit] = Future {
      synchronized {
        total += amount
      }
    }

    def count(): Future[Long] = Future {
      synchronized(total)
    }
  }
}
