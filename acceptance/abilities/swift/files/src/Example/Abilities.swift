// User-owned LawSpec adapter: a native Gateway handler and a native adapter
// that uses Gateway through the handler it is given.
// ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Abilities {
    /// (Int32 -> Bool)
    static func charge(_ gateway: any LawSpec.Abilities.ExampleAbilities.Gateway, _ value0: Int32) -> Bool {
        switch gateway.authorize(value0) {
        case .approved(let cents): return gateway.capture(cents).cents == value0
        case .declined: return false
        }
    }

    /// The native handler of Gateway: authorize, capture, fee.
    static func gatewayHandler() -> any LawSpec.Abilities.ExampleAbilities.Gateway { NativeGateway() }

    struct NativeGateway: LawSpec.Abilities.ExampleAbilities.Gateway {
        func authorize(_ value0: Int32) -> Payment { value0 < 0 ? .declined : .approved(value: value0) }
        func capture(_ value0: Int32) -> Receipt { Receipt(cents: value0) }
        func fee() -> Int32 { 25 }
    }
}
