// User-owned LawSpec adapter: native adapters that fail with a typed throw,
// and the native Gateway handler.
// ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Failures {
    /// (Int32 -> Int32)
    static func refund(_ value0: Int32) throws(PaymentError) -> Int32 {
        if value0 > 5000 { throw .tooLarge(limit: 5000) }
        return value0
    }

    /// (Int32 -> Int32)
    static func settle(_ value0: Int32) async throws(PaymentError) -> Int32 {
        await Task.yield()
        if value0 < 0 { throw .blocked }
        if value0 == 0 { throw .declined(message: "there is nothing to settle") }
        return value0
    }

    /// The native handler of Gateway: decide.
    static func gatewayHandler() -> any LawSpec.Abilities.ExampleFailures.Gateway {
        NativeGateway()
    }

    struct NativeGateway: LawSpec.Abilities.ExampleFailures.Gateway {
        func decide(_ value0: Int32) -> Decision {
            if value0 < 0 { return .block }
            if value0 % 2 != 0 { return .decline(reason: "an odd amount") }
            return .approve
        }
    }
}
