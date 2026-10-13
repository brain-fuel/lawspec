// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Refinements {
    static func add(_ a: Int8, _ b: Int8) -> BigInt { BigInt(a) + BigInt(b) }
    static func successor(_ a: Int8) -> BigInt { BigInt(a) + 1 }
    static func count(_ text: String) -> BigInt { BigInt(text.unicodeScalars.count) }
    static func preserve(_ a: UInt64) -> BigInt { BigInt(a) }
    static func positive(_ a: Int8) -> Int8 { a }
    static func abstractEcho(_ a: BigInt) -> BigInt { a }
}
