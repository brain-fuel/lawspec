// User-owned LawSpec adapter.
import Foundation
import LawSpecRuntime

extension Example.ParsePort {
    static func validPort(_ x: Int32) -> Bool { x >= 1 && x <= 65535 }
    static func render(_ x: Int32) -> String {
        guard validPort(x) else { fatalError("invalid port") }
        return String(x)
    }
    static func parse(_ x: String) -> Int32 { Int32(x) ?? 0 }
}
