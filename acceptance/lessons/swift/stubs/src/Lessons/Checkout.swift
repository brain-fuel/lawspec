// User-owned LawSpec adapter. Implement these functions.
import LawSpecRuntime

extension Lessons.Checkout {
    /// (lessons.checkout::type::RawOrder -> Either (lessons.checkout::type::OrderProblem) (lessons.checkout::type::ValidOrder))
    static func validate(_ value0: RawOrder) -> Either<OrderProblem, ValidOrder> {
        fatalError("not implemented: lessons.checkout::validate")
    }

    /// (lessons.checkout::type::ValidOrder -> lessons.checkout::type::Receipt)
    static func charge(_ value0: ValidOrder) -> Receipt {
        fatalError("not implemented: lessons.checkout::charge")
    }
}
