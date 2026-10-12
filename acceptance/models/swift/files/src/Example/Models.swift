// User-owned LawSpec adapter: a persistent stack and an atomic counter.
import Foundation
import LawSpecRuntime

/// The counters, by id, behind one lock.
final class Counters: @unchecked Sendable {
    let gate = NSLock()
    var counts = [Int32: Int64]()
    var ids: Int32 = 0

    func update(_ id: Int32, _ change: (Int64) -> Int64) -> Int64 {
        gate.lock()
        defer { gate.unlock() }
        let next = change(counts[id] ?? 0)
        counts[id] = next
        return next
    }
}

private let counters = Counters()

extension Example.Models {
    static func empty() -> Stack { .empty }

    static func push(_ value0: Int8, _ value1: Stack) -> PushFlow { PushFlow(state: .push(top: value0, rest: value1)) }

    /// The flow signature guarantees a nonempty stack.
    static func pop(_ value0: Stack) -> PopFlow {
        switch value0 {
        case .push(let top, let rest): return PopFlow(result: top, state: rest)
        case .empty: fatalError("pop needs a nonempty stack")
        }
    }

    static func peek(_ value0: Stack) -> PeekFlow {
        switch value0 {
        case .push(let top, _): return PeekFlow(result: top, state: value0)
        case .empty: fatalError("peek needs a nonempty stack")
        }
    }

    static func newCounter() -> Counter {
        counters.gate.lock()
        defer { counters.gate.unlock() }
        counters.ids += 1
        counters.counts[counters.ids] = 0
        return Counter(id: counters.ids)
    }

    static func increment(_ value0: Counter) async -> Int64 {
        await Task.yield()
        return counters.update(value0.id) { $0 + 1 }
    }

    static func decrement(_ value0: Counter) async -> Int64 {
        await Task.yield()
        return counters.update(value0.id) { $0 - 1 }
    }

    static func read(_ value0: Counter) async -> Int64 {
        await Task.yield()
        return counters.update(value0.id) { $0 }
    }
}
