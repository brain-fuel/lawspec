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
    fun firstLine(value0: NonEmptyList<Int>): Int = value0.value[0]

    fun validateOrder(value0: UnvalidatedOrder): LawSpecRuntime.Either<OrderError, ValidatedOrder> {
        if (value0.id.isEmpty()) return LawSpecRuntime.Left(OrderError.InvalidOrderId)
        if (value0.quantity !in 1..1000) return LawSpecRuntime.Left(OrderError.InvalidQuantity)
        return LawSpecRuntime.Right(
            ValidatedOrder(OrderId(value0.id), UnitQuantity(value0.quantity)),
        )
    }

    fun priceOrder(value0: ValidatedOrder): LawSpecRuntime.Either<OrderError, PricedOrder> {
        val total = value0.quantity.value.toLong() * 25
        if (total > 20000) return LawSpecRuntime.Left(OrderError.PriceTooHigh)
        return LawSpecRuntime.Right(PricedOrder(value0.id, value0.quantity, total))
    }

    fun placeOrder(value0: UnvalidatedOrder): LawSpecRuntime.Either<OrderError, PricedOrder> {
        val validated = validateOrder(value0)
        if (validated is LawSpecRuntime.Left) return LawSpecRuntime.Left(validated.value())
        return priceOrder((validated as LawSpecRuntime.Right).value())
    }
}
