// User-owned LawSpec adapter.
package example

import lawspec.data.{NonEmptyList, OrderError, OrderId, PricedOrder, UnitQuantity, UnvalidatedOrder, ValidatedOrder}

object Ordering {
  // (example.ordering::type::NonEmptyList (Int32) -> Int32)
  def firstLine(value0: lawspec.data.NonEmptyList[scala.Int]): scala.Int =
    value0.value.head

  // (example.ordering::type::UnvalidatedOrder -> Either (example.ordering::type::OrderError)
  // (example.ordering::type::ValidatedOrder))
  def validateOrder(
    value0: lawspec.data.UnvalidatedOrder,
  ): scala.util.Either[lawspec.data.OrderError, lawspec.data.ValidatedOrder] =
    if (value0.id.isEmpty) Left(OrderError.InvalidOrderId)
    else if (value0.quantity < 1 || value0.quantity > 1000) Left(OrderError.InvalidQuantity)
    else Right(ValidatedOrder(OrderId(value0.id), UnitQuantity(value0.quantity)))

  // (example.ordering::type::ValidatedOrder -> Either (example.ordering::type::OrderError)
  // (example.ordering::type::PricedOrder))
  def priceOrder(
    value0: lawspec.data.ValidatedOrder,
  ): scala.util.Either[lawspec.data.OrderError, lawspec.data.PricedOrder] = {
    val total = value0.quantity.value.toLong * 25
    if (total > 20000) Left(OrderError.PriceTooHigh)
    else Right(PricedOrder(value0.id, value0.quantity, total))
  }
}
