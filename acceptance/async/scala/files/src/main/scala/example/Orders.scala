// User-owned LawSpec adapter.
package example

import scala.concurrent.Future

object Orders {
  private def priceOf(sku: String): Int =
    if (sku == "free") 0 else sku.codePointCount(0, sku.length) % 100

  // (Text -> Int32)
  def price(value0: java.lang.String): scala.concurrent.Future[scala.Int] =
    Future.successful(priceOf(value0))

  // (Text -> Int32)
  def stock(value0: java.lang.String): scala.concurrent.Future[scala.Int] =
    Future.successful(value0.codePointCount(0, value0.length))

  // (Text -> Int32)
  def quote(value0: java.lang.String): scala.Int = priceOf(value0)
}
