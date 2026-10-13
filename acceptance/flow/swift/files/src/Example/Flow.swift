// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Flow {
    static func push(_ value: Int8, _ stack: Stack) -> PushFlow { PushFlow(state: .push(top: value, rest: stack)) }

    /// The flow signature guarantees a nonempty stack.
    static func pop(_ stack: Stack) -> PopFlow {
        switch stack {
        case .push(let top, let rest): return PopFlow(result: top, state: rest)
        case .empty: fatalError("an empty stack")
        }
    }

    static func peek(_ stack: Stack) -> PeekFlow {
        switch stack {
        case .push(let top, _): return PeekFlow(result: top, state: stack)
        case .empty: fatalError("an empty stack")
        }
    }
}
