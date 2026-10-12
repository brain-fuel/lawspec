// User-owned LawSpec adapter: the approve workflow under the real clock.
// ref:DEC-acceptance-with-mutants
import Foundation
import LawSpecRuntime

extension Example.Approvals {
    /// Approves an order: whether it took less than 550ms.
    static func approvedQuickly(_ number: Int64) async -> Bool {
        let started = ContinuousClock.now
        _ = Workflow.withReal(0) { _ in LawSpec.Definitions.ExampleWorkflows.approve(Order(number: number)) }
        return ContinuousClock.now - started < .milliseconds(550)
    }

    /// Approves an order: the messages of its failures, as reported.
    static func approvalErrors(_ number: Int64) async -> [String] {
        Finished.shared.clear()
        let result = Workflow.withReal(0) { _ in LawSpec.Definitions.ExampleWorkflows.approve(Order(number: number)) }
        switch result {
        case .left(.approveFailures(let failures)):
            return failures.compactMap { failure in
                switch failure {
                case .approveCheckStockFailed(let e), .approveCheckCreditFailed(let e): return e
                default: return nil
                }
            }
        default:
            return []
        }
    }
}
