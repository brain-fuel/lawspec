// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import Foundation
import LawSpecRuntime

extension Example.Currying {
    static func sumFour(_ a: BigInt, _ b: BigInt, _ c: BigInt, _ d: BigInt) -> BigInt { a + b + c + d }

    static func format(_ prefix: String, _ enabled: Bool, _ port: Int32, _ suffix: String) -> String {
        prefix + (enabled ? String(port) : "") + suffix
    }

    static func referenceFormat(_ prefix: String, _ enabled: Bool, _ port: Int32, _ suffix: String) -> String {
        [prefix, enabled ? String(port) : "", suffix].joined()
    }

    static func trim(_ x: String) -> String { x.trimmingCharacters(in: .whitespacesAndNewlines) }
}
