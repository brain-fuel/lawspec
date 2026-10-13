// User-owned LawSpec adapter.
import Foundation
import LawSpecRuntime

extension Example.Alternatives {
    static func render(_ x: Int32) -> String { String(x) }
    static func referenceRender(_ x: Int32) -> String { "\(x)" }
    static func clamp(_ x: Int32) -> Int32 { max(0, x) }
    static func referenceClamp(_ x: Int32) -> Int32 { x < 0 ? 0 : x }
}
