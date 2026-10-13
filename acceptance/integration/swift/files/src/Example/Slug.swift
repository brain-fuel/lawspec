// User-owned LawSpec adapter.
import Foundation
import LawSpecRuntime

extension Example.Slug {
    static func normalize(_ x: String) -> String { x.replacingOccurrences(of: " ", with: "-") }
    static func referenceNormalize(_ x: String) -> String { String(x.map { $0 == " " ? "-" : $0 }) }
}
