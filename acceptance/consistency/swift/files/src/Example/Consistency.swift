// User-owned LawSpec adapter: a page-view counter with one replica per thread.
import Foundation
import LawSpecRuntime

/// Each counter's replicas, one per thread, behind one lock.
final class Replicas: @unchecked Sendable {
    let gate = NSLock()
    var replicas = [Int32: [UInt64: Int64]]()
    var ids: Int32 = 0
}

private let state = Replicas()

extension Example.Consistency {
    private static func me() -> UInt64 {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        return id
    }

    static func newViews() -> Views {
        state.gate.lock()
        defer { state.gate.unlock() }
        let id = state.ids
        state.ids += 1
        state.replicas[id] = [:]
        return Views(id: id)
    }

    static func hit(_ value0: Views) -> Int64 {
        state.gate.lock()
        defer { state.gate.unlock() }
        let me = me()
        let count = (state.replicas[value0.id]?[me] ?? 0) + 1
        state.replicas[value0.id]?[me] = count
        return count
    }

    static func total(_ value0: Views) -> Int64 {
        state.gate.lock()
        defer { state.gate.unlock() }
        return (state.replicas[value0.id] ?? [:]).values.reduce(0, +)
    }
}
