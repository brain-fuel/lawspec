// User-owned LawSpec adapter.
package example

import lawspec.data.NonEmptyList
import lawspec.data.OrderError
import lawspec.data.OrderId
import lawspec.data.PricedOrder
import lawspec.data.UnitQuantity
import lawspec.data.UnvalidatedOrder
import lawspec.data.ValidatedOrder
import lawspec.runtime.LawSpecRuntime

object Ordering {
    fun firstLine(value0: NonEmptyList<Int>): Int = (value0 as NonEmptyList.NonEmptyListCase).value[0]

    fun validateOrder(value0: UnvalidatedOrder): LawSpecRuntime.Either<OrderError, ValidatedOrder> {
        val input = value0 as UnvalidatedOrder.UnvalidatedOrderCase
        if (input.id.isEmpty()) return LawSpecRuntime.Left(OrderError.InvalidOrderIdCase())
        if (input.quantity !in 1..1000) return LawSpecRuntime.Left(OrderError.InvalidQuantityCase())
        return LawSpecRuntime.Right(
            ValidatedOrder.ValidatedOrderCase(OrderId.OrderIdCase(input.id), UnitQuantity.UnitQuantityCase(input.quantity)),
        )
    }

    fun priceOrder(value0: ValidatedOrder): LawSpecRuntime.Either<OrderError, PricedOrder> {
        val order = value0 as ValidatedOrder.ValidatedOrderCase
        val total = (order.quantity as UnitQuantity.UnitQuantityCase).value.toLong() * 25
        if (total > 20000) return LawSpecRuntime.Left(OrderError.PriceTooHighCase())
        return LawSpecRuntime.Right(PricedOrder.PricedOrderCase(order.id, order.quantity, total))
    }

    fun placeOrder(value0: UnvalidatedOrder): LawSpecRuntime.Either<OrderError, PricedOrder> {
        val validated = validateOrder(value0)
        if (validated is LawSpecRuntime.Left) return LawSpecRuntime.Left(validated.value())
        return priceOrder((validated as LawSpecRuntime.Right).value())
    }
}
