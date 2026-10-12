// User-owned LawSpec adapter.
import LawSpecRuntime

extension Lessons.Pricing {
    static func priceInCents(_ value0: Int32) -> Int64 { Int64(value0) * (value0 >= 10 ? 225 : 250) }
}
