// User-owned LawSpec adapter.
import Foundation
import LawSpecRuntime

extension Example.AtoiCodec {
    static func itoa(_ value: Int32) -> String { String(value) }
    static func atoi(_ value: String) -> Int32 { Int32(value) ?? 0 }
}
