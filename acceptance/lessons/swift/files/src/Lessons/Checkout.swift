// User-owned LawSpec adapter.
import LawSpecRuntime

extension Lessons.Checkout {
    static func validate(_ value0: RawOrder) -> Either<OrderProblem, ValidOrder> {
        if value0.item.isEmpty { return .left(.emptyItem) }
        if value0.quantity < 1 || value0.quantity > 20 { return .left(.badQuantity) }
        return .right(ValidOrder(item: value0.item, quantity: Quantity(value: value0.quantity)))
    }

    static func charge(_ value0: ValidOrder) -> Receipt {
        Receipt(item: value0.item, total: Int64(value0.quantity.value) * 250)
    }
}
