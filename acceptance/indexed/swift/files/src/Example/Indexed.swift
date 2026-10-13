// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Indexed {
    static func replicate(_ value0: BigInt, _ value1: Int8) -> Vec<Int8> {
        var result = Vec<Int8>.vNil
        var i = BigInt.zero
        while i < value0 {
            result = .vCons(head: value1, tail: result)
            i += 1
        }
        return result
    }

    static func append(_ value0: Vec<Int8>, _ value1: Vec<Int8>) -> Vec<Int8> {
        switch value0 {
        case .vCons(let head, let tail): return .vCons(head: head, tail: append(tail, value1))
        case .vNil: return value1
        }
    }

    static func zip(_ value0: Vec<Int8>, _ value1: Vec<Bool>) -> Vec<Bool> {
        switch (value0, value1) {
        case (.vCons(_, let tail0), .vCons(let head1, let tail1)): return .vCons(head: head1, tail: zip(tail0, tail1))
        default: return .vNil
        }
    }

    static func flatten(_ value0: ExampleIndexedTree<Int8>) -> Vec<Int8> {
        switch value0 {
        case .tip: return .vNil
        case .bin(let left, let value, let right):
            let rest = Vec<Int8>.vCons(head: value, tail: flatten(right))
            return append(flatten(left), rest)
        }
    }
}
