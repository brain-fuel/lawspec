// User-owned LawSpec adapter.
import LawSpecRuntime

extension Lessons.Codec {
    static func formatQuantity(_ value0: Int32) -> String { String(value0) }

    static func parseQuantity(_ value0: String) -> Int32 { Int32(value0) ?? 0 }
}
