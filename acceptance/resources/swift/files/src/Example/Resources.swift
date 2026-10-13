// User-owned LawSpec adapters for the resources example.
// ref:REQ-law-primitives ref:DEC-acceptance-with-mutants
import Foundation
import LawSpecRuntime

/// An in-memory store. At most three may be open at once, so a store that is
/// never closed is noticed.
final class StoreState: @unchecked Sendable {
    nonisolated(unsafe) static var openCount = 0
    var items = [Int32: Int32]()
    var isOpen = true

    init() {
        if StoreState.openCount >= 3 { fatalError("too many open stores: one was never closed") }
        StoreState.openCount += 1
    }

    func close() {
        if isOpen {
            isOpen = false
            StoreState.openCount -= 1
        }
    }
}

/// A pool that is costly to open: this process may open only one, so the
/// suite passes only if the harness shares it (share Pool per unit).
final class PoolState: @unchecked Sendable {
    nonisolated(unsafe) static var opened = 0
    var amount: Int32 = 0
    var isOpen = true
}

extension Example.Resources {
    private static func store(_ value: Store) -> StoreState { value.object as! StoreState }
    private static func pool(_ value: Pool) -> PoolState { value.object as! PoolState }

    static func openStore() -> Store { AnyHandle(StoreState()) }

    static func closeStore(_ value0: Store) { store(value0).close() }

    static func clearStore(_ value0: Store) { store(value0).items.removeAll() }

    static func put(_ value0: Store, _ key: Int32, _ item: Int32) {
        let s = store(value0)
        if !s.isOpen { fatalError("the store is closed") }
        s.items[key] = item
    }

    static func get(_ value0: Store, _ key: Int32) -> Int32? {
        let s = store(value0)
        if !s.isOpen { fatalError("the store is closed") }
        return s.items[key]
    }

    static func isOpen(_ value0: Store) -> Bool { store(value0).isOpen }

    static func size(_ value0: Store) -> Int32 { Int32(store(value0).items.count) }

    static func writeNote(_ folder: String, _ note: Int32) {
        try! String(note).write(toFile: (folder as NSString).appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    }

    static func readNote(_ folder: String) -> Int32? {
        let note = (folder as NSString).appendingPathComponent("note.txt")
        guard let text = try? String(contentsOfFile: note, encoding: .utf8) else { return nil }
        return Int32(text)
    }

    static func canListen(_ port: Int32) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if socket < 0 { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return bound == 0 && listen(socket, 1) == 0
    }

    static func setGreeting(_ value0: Int32) { setenv("LAWSPEC_EXAMPLE_GREETING", String(value0), 1) }

    static func greeting() -> Int32? {
        guard let text = getenv("LAWSPEC_EXAMPLE_GREETING") else { return nil }
        return Int32(String(cString: text))
    }

    static func openPool() -> Pool {
        if PoolState.opened >= 1 { fatalError("a second pool was opened: the harness should share it") }
        PoolState.opened += 1
        return AnyHandle(PoolState())
    }

    static func drainPool(_ value0: Pool) { pool(value0).amount = 0 }

    static func closePool(_ value0: Pool) { pool(value0).isOpen = false }

    static func fill(_ value0: Pool, _ amount: Int32) {
        let p = pool(value0)
        if !p.isOpen { fatalError("the pool is closed") }
        p.amount += amount
    }

    static func level(_ value0: Pool) -> Int32 { pool(value0).amount }
}
