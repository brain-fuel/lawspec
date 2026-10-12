// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Ordering {
    /// (example.ordering::type::NonEmptyList (Int32) -> Int32)
    static func firstLine(_ value0: NonEmptyList<Int32>) -> Int32 {
        value0.value.first!
    }

    /// (example.ordering::type::UnvalidatedOrder -> Either (example.ordering::type::OrderError) (example.ordering::type::ValidatedOrder))
    static func validateOrder(_ value0: UnvalidatedOrder) -> Either<OrderError, ValidatedOrder> {
        if value0.id.isEmpty { return .left(.invalidOrderId) }
        if value0.quantity < 1 || value0.quantity > 1000 { return .left(.invalidQuantity) }
        return .right(ValidatedOrder(id: OrderId(value: value0.id), quantity: UnitQuantity(value: value0.quantity)))
    }

    /// (example.ordering::type::ValidatedOrder -> Either (example.ordering::type::OrderError) (example.ordering::type::PricedOrder))
    static func priceOrder(_ value0: ValidatedOrder) -> Either<OrderError, PricedOrder> {
        let total = Int64(value0.quantity.value) * 25
        if total > 20000 { return .left(.priceTooHigh) }
        return .right(PricedOrder(id: value0.id, quantity: value0.quantity, total: total))
    }
}
