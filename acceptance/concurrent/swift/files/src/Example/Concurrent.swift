// User-owned LawSpec adapter: a queue, a set and a map shared between
// threads, each behind a lock of its own.
import Foundation
import LawSpecRuntime

/// A structure shared between threads: its contents behind a lock.
final class Shared<Contents>: @unchecked Sendable {
    private var contents: Contents
    private let gate = NSLock()
    init(_ contents: Contents) { self.contents = contents }
    func with<R>(_ body: (inout Contents) -> R) -> R {
        gate.lock()
        defer { gate.unlock() }
        return body(&contents)
    }
}

private let ids = Shared(Int32(0))
private let queues = Shared([Int32: Shared<[Int32]>]())
private let sets = Shared([Int32: Shared<Set<Int32>>]())
private let maps = Shared([Int32: Shared<[Int8: Int64]>]())

extension Example.Concurrent {
    /// A structure by its handle; generated tests may name one first.
    private static func queue(_ handle: WorkQueue) -> Shared<[Int32]> {
        queues.with { table in table[handle.id] ?? { let made = Shared([Int32]()); table[handle.id] = made; return made }() }
    }

    private static func set(_ handle: Tags) -> Shared<Set<Int32>> {
        sets.with { table in table[handle.id] ?? { let made = Shared(Set<Int32>()); table[handle.id] = made; return made }() }
    }

    private static func map(_ handle: Cache) -> Shared<[Int8: Int64]> {
        maps.with { table in table[handle.id] ?? { let made = Shared([Int8: Int64]()); table[handle.id] = made; return made }() }
    }

    private static func fresh() -> Int32 { ids.with { $0 += 1; return $0 } }

    static func newQueue() -> WorkQueue {
        let handle = WorkQueue(id: fresh())
        _ = queue(handle)
        return handle
    }

    static func offer(_ value0: WorkQueue, _ value1: Int32) async {
        await Task.yield()
        queue(value0).with { $0.append(value1) }
    }

    static func poll(_ value0: WorkQueue) async -> Int32? {
        await Task.yield()
        return queue(value0).with { q in q.isEmpty ? nil : q.removeFirst() }
    }

    static func queueSize(_ value0: WorkQueue) async -> Int64 {
        await Task.yield()
        return queue(value0).with { Int64($0.count) }
    }

    static func newTags() -> Tags {
        let handle = Tags(id: fresh())
        _ = set(handle)
        return handle
    }

    static func tag(_ value0: Tags, _ value1: Int32) async -> Bool {
        await Task.yield()
        return set(value0).with { $0.insert(value1).inserted }
    }

    static func untag(_ value0: Tags, _ value1: Int32) async -> Bool {
        await Task.yield()
        return set(value0).with { $0.remove(value1) != nil }
    }

    static func tagged(_ value0: Tags, _ value1: Int32) async -> Bool {
        await Task.yield()
        return set(value0).with { $0.contains(value1) }
    }

    static func newCache() -> Cache {
        let handle = Cache(id: fresh())
        _ = map(handle)
        return handle
    }

    static func store(_ value0: Cache, _ value1: Int8, _ value2: Int64) async -> Int64? {
        await Task.yield()
        return map(value0).with { m in
            let old = m[value1]
            m[value1] = value2
            return old
        }
    }

    static func fetch(_ value0: Cache, _ value1: Int8) async -> Int64? {
        await Task.yield()
        return map(value0).with { $0[value1] }
    }

    static func evict(_ value0: Cache, _ value1: Int8) async -> Int64? {
        await Task.yield()
        return map(value0).with { $0.removeValue(forKey: value1) }
    }
}
