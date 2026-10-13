// User-owned LawSpec adapter.
import Foundation
import LawSpecRuntime

extension Example.CanonicalUrl {
    static func canonicalize(_ x: String) -> String {
        var text = x
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
