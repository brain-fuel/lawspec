// User-owned LawSpec adapter.
import LawSpecRuntime

extension Lessons.Discounts {
    static func applyDiscount(_ value0: Int64, _ value1: Int32) -> Int64 { value0 * Int64(100 - value1) / 100 }
}
