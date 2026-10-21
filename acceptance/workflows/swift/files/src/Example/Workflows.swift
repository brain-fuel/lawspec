// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import Foundation
import LawSpecRuntime

/// Each check records when it fails, so approvalErrors can tell completion
/// order from declaration order.
final class Finished: @unchecked Sendable {
    static let shared = Finished()
    private let gate = NSLock()
    private var problems = [String]()

    func add(_ problem: String) {
        gate.lock()
        problems.append(problem)
        gate.unlock()
    }

    func clear() {
        gate.lock()
        problems.removeAll()
        gate.unlock()
    }

    var all: [String] {
        gate.lock()
        defer { gate.unlock() }
        return problems
    }
}

/// Order -1's slow checks record when they ran, so approvedQuickly can tell
/// whether they ran at the same time. The record is never cleared, so tests
/// running at once cannot erase each other's.
final class Spans: @unchecked Sendable {
    static let shared = Spans()
    private let gate = NSLock()
    private var ran = [(ContinuousClock.Instant, ContinuousClock.Instant)]()

    func add(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) {
        gate.lock()
        ran.append((start, end))
        gate.unlock()
    }

    /// Whether two slow checks that started at or after since overlapped.
    func overlapped(since: ContinuousClock.Instant) -> Bool {
        gate.lock()
        defer { gate.unlock() }
        let recent = ran.filter { $0.0 >= since }
        for i in recent.indices {
            for j in recent.indices where j > i {
                if recent[i].0 < recent[j].1 && recent[j].0 < recent[i].1 { return true }
            }
        }
        return false
    }
}

extension Example.Workflows {
    static func audit(_ value0: Account) -> Bool { true }

    static func waitlist(_ error: SignupError) -> Either<SignupError, Account> {
        if case .unavailable = error { return .right(Account(name: "waitlist", age: 18, level: 0)) }
        return .left(error)
    }

    static func checkName(_ signup: Signup) -> Either<SignupError, Signup> {
        signup.name.isEmpty ? .left(.missingName) : .right(signup)
    }

    static func checkAge(_ signup: Signup) -> Either<String, Signup> {
        signup.age < 18 ? .left("too young") : .right(signup)
    }

    static func openAccount(_ signup: Signup) -> Either<SignupError, Account> {
        signup.name == "taken" ? .left(.unavailable) : .right(Account(name: signup.name, age: signup.age, level: 1))
    }

    private static func check(_ order: Order, _ milliseconds: UInt64, _ problem: String) async -> Either<String, Order> {
        if order.number == -1 {
            let start = ContinuousClock.now
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            Spans.shared.add(start, ContinuousClock.now)
        }
        if order.number >= 0 { return .right(order) }
        Finished.shared.add(problem)
        return .left(problem)
    }

    /// Order -1's stock check takes 400ms; a negative order has no stock.
    static func checkStock(_ order: Order) async -> Either<String, Order> { await check(order, 400, "no stock") }

    /// Order -1's credit check takes 250ms; a negative order has no credit.
    static func checkCredit(_ order: Order) async -> Either<String, Order> { await check(order, 250, "no credit") }
}
