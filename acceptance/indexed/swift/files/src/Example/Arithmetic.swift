// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Arithmetic {
    private static func length(_ row: Row) -> Int64 {
        switch row {
        case .end: return 0
        case .cell(.record(_, let tail)): return 1 + length(tail)
        }
    }

    static func mirror(_ value0: Perfect) -> Perfect {
        switch value0 {
        case .leaf: return value0
        case .node(.record(let left, let right)): return .node(value: .record(left: mirror(right), right: mirror(left)))
        }
    }

    static func area(_ value0: Grid) -> BigInt { BigInt(length(value0.value.rows) * length(value0.value.columns)) }

    static func duplicate(_ value0: Row) -> Halves { Halves(value: HalvesDetails(back: value0, front: value0)) }

    static func countPairs(_ value0: Row) -> Pairs { Pairs(value: value0) }

    static func dropFirst(_ value0: Row) -> Rest { Rest(value: value0) }
}
