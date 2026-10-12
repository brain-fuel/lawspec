// User-owned LawSpec adapter. ref:REQ-harness-units ref:DEC-tests-cite-requirements
import LawSpecRuntime

extension Example.Harness {
    static func discount(_ order: Order) -> Int32 { order.items > 10 ? order.total / 10 : 0 }

    static func roundCents(_ cents: Int32) -> Int32 { (cents + 4) / 10 * 10 }

    static func book(_ ledger: any LawSpec.Abilities.ExampleHarness.Ledger, _ cents: Int32) -> Bool { ledger.accept(cents) }

    static func ledgerHandler() -> any LawSpec.Abilities.ExampleHarness.Ledger { NativeLedger() }

    struct NativeLedger: LawSpec.Abilities.ExampleHarness.Ledger {
        func accept(_ cents: Int32) -> Bool { cents > 0 }
    }
}
