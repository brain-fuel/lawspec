// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import LawSpecRuntime

// Swift enums cannot refine their type arguments per case, so a switch ends
// with the cases no value of the refined type has.
extension Example.Gadt {
    /// (example.gadt::type::Expr (BigInt) -> BigInt)
    static func evalNumber(_ value0: Expr<BigInt>) -> BigInt {
        switch value0 {
        case .number(let n): return n
        case .plus(.record(let left, let right)):
            return evalNumber(left) + evalNumber(right)
        default: fatalError("not an Expr<BigInt>")
        }
    }

    /// (example.gadt::type::Expr (Bool) -> Bool)
    static func evalTruth(_ value0: Expr<Bool>) -> Bool {
        switch value0 {
        case .truth(let b): return b
        case .same(.record(let left, let right)):
            return evalNumber(left) == evalNumber(right)
        case .negate(let operand): return !evalTruth(operand)
        default: fatalError("not an Expr<Bool>")
        }
    }

    /// Both's fields have the types its equation binds (Expr<BigInt> and
    /// Expr<Bool> here); Swift types them Expr<Value>, so they are retyped
    /// through their portable value.
    private static func retype<T>(_ codec: Codec<T>, _ value: Expr<Value>) -> Expr<T> {
        try! LawSpec.DataCodecs.expr(codec).toNative(LawSpec.DataCodecs.expr(Codecs.portable).fromNative(value))
    }

    /// (example.gadt::type::Expr (example.gadt::type::Pair (BigInt) (Bool)) -> example.gadt::type::Pair (BigInt) (Bool))
    static func evalPair(_ value0: Expr<Pair<BigInt, Bool>>) -> Pair<BigInt, Bool> {
        switch value0 {
        case .both(.record(let first, let second)):
            return Pair(first: evalNumber(retype(Codecs.bigInt, first)), second: evalTruth(retype(Codecs.bool, second)))
        default: fatalError("not an Expr<Pair<BigInt, Bool>>")
        }
    }

    /// (example.gadt::type::Expr (BigInt) -> example.gadt::type::Expr (BigInt))
    static func fold(_ value0: Expr<BigInt>) -> Expr<BigInt> {
        .number(value: evalNumber(value0))
    }

    /// (example.gadt::type::Shown -> Text)
    static func describe(_ value0: Shown) -> String {
        switch value0 {
        case .shown(_, let witness): return witness
        }
    }
}
