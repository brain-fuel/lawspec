// User-owned LawSpec adapter.
import LawSpecRuntime

extension Lessons.Orders {
    static func price(_ value0: Drink) -> Int64 {
        let size: Int64 = value0.size == .large ? 320 : 250
        return size + Int64(value0.shots) * 60
    }
}
