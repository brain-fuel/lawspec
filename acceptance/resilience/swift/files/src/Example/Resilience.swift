// User-owned LawSpec adapter: the workflow runtime under test.
// ref:DEC-acceptance-with-mutants
import Foundation
import LawSpecRuntime

extension Example.Resilience {
    static func runtimeExponentialDelay(_ delay: BigInt, _ factor: BigInt, _ attempt: BigInt) -> BigInt {
        BigInt(try! Policy.retryDelay(Policy.exponential(delay.truncated(Int64.self), factor.truncated(Int64.self), nil), attempt.truncated(Int64.self)))
    }

    static func runtimeLinearDelay(_ delay: BigInt, _ step: BigInt, _ attempt: BigInt) -> BigInt {
        BigInt(try! Policy.retryDelay(Policy.linear(delay.truncated(Int64.self), step.truncated(Int64.self)), attempt.truncated(Int64.self)))
    }

    static func runtimeFibonacciDelay(_ delay: BigInt, _ attempt: BigInt) -> BigInt {
        BigInt(try! Policy.retryDelay(Policy.fibonacciDelay(delay.truncated(Int64.self)), attempt.truncated(Int64.self)))
    }

    static func splitMix(_ seed: UInt64, _ count: Int32) -> PersistentList<UInt64> {
        var state = Random.seed(BigInt(seed))
        return PersistentList((0..<max(0, count)).map { _ in
            let (n, next) = Random.next(state)
            state = next
            return n
        })
    }

    static func fullJitter(_ seed: UInt64, _ delay: BigInt) -> BigInt {
        BigInt(Policy.jitter(.full, delay.truncated(Int64.self), 0, 0, Random.seed(BigInt(seed))).0)
    }

    private static func waits(_ attempts: Int32, _ accepts: Bool) -> PersistentList<BigInt> {
        Workflow.withVirtual(0) { runtime in
            let retry = Policy.retry(Policy.exponential(100_000, 2, nil), Int64(attempts), .none, { _ in .bool(accepts) })
            let stage = Policy.stage("stage", "stage", retry, nil, [], nil, nil, false, nil)
            _ = try! Workflow.runStage(LawSpec.Program.schema, stage, { .data("Either::Left", [.int(0)]) }, .unit)
            return PersistentList(Workflow.trace(runtime).filter { $0.kind == "sleep" }.map { BigInt($0.number) })
        }
    }

    static func retriedWaits(_ attempts: Int32) -> PersistentList<BigInt> { waits(attempts, true) }

    static func rejectedWaits(_ attempts: Int32) -> PersistentList<BigInt> { waits(attempts, false) }

    /// Calls the generated workflow at each time under one runtime.
    static func limitedAt(_ times: PersistentList<BigInt>) -> PersistentList<Bool> {
        Workflow.withVirtual(0) { runtime in
            PersistentList(times.map { time in
                try! Workflow.setTime(runtime, time.truncated(Int64.self))
                if case .right = LawSpec.Definitions.ExampleLimits.limited(Ticket(number: 0)) { return true }
                return false
            })
        }
    }

    /// Books a ticket under a fresh runtime: the stages whose undos ran.
    static func compensationsFor(_ number: Int64) -> PersistentList<String> {
        Workflow.withVirtual(0) { runtime in
            _ = LawSpec.Definitions.ExampleLimits.book(Ticket(number: number))
            return PersistentList(Workflow.trace(runtime).filter { $0.kind == "compensate" }.map { $0.stage })
        }
    }

    /// Quotes a ticket under a runtime with the real clock: whether it timed out.
    static func quoteTimedOut(_ number: Int64) async -> Bool {
        Workflow.withReal(0) { _ in
            if case .left(.quotedTimedOut) = LawSpec.Definitions.ExampleLimits.quoted(Ticket(number: number)) { return true }
            return false
        }
    }

    /// Quotes a ticket under a runtime with the real clock: whether it succeeded
    /// within 400ms, for ticket -2 through a hedged attempt.
    static func quoteHedged(_ number: Int64) async -> Bool {
        Example.Limits.resetQuotes()
        return Workflow.withReal(0) { runtime in
            let started = ContinuousClock.now
            let result = LawSpec.Definitions.ExampleLimits.hedged(Ticket(number: number))
            let quick = ContinuousClock.now - started < .milliseconds(400)
            let hedged = Workflow.trace(runtime).contains { $0.kind == "hedge" }
            var succeeded = false
            if case .right = result { succeeded = true }
            return succeeded && quick && (number != -2 || hedged)
        }
    }
}
