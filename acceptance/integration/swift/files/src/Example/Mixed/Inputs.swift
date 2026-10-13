// User-owned LawSpec adapter.
import Foundation
import LawSpecRuntime

extension Example.Mixed.Inputs {
    static func normalize(_ x: String) -> String { x.replacingOccurrences(of: " ", with: "-") }
    static func identity(_ x: Int32) -> Int32 { x }
}
