// User-owned LawSpec adapter. class is a Swift keyword, so the adapter is `class`.
// ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Keywords {
    static func `class`(_ value0: BigInt) -> BigInt { value0 << 1 }
}
