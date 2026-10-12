// User-owned LawSpec adapter.
import LawSpecRuntime

extension Lessons.Evidence {
    static func isWeekend(_ value0: Int8) -> Bool { value0 == 0 || value0 == 6 }

    /// Truncate toward zero: the remainder has the dividend's sign, so the most
    /// negative Int64 cannot overflow.
    static func roundToDollars(_ value0: Int64) -> Int64 { value0 - value0 % 100 }
}
