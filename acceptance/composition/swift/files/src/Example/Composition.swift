// User-owned LawSpec adapter: native handlers of Logs, Reader and Writer that
// share the case's Store. ref:DEC-acceptance-with-mutants
import LawSpecRuntime

/// An in-memory log store: each log's records, newest last.
final class LogStore: @unchecked Sendable {
    var logs = [String: [String]]()
    var isOpen = true
}

extension Example.Composition {
    private static func logStore(_ store: Store) -> LogStore { store.object as! LogStore }

    static func openStore() -> Store { AnyHandle(LogStore()) }

    static func closeStore(_ store: Store) { logStore(store).isOpen = false }

    /// The native handler of Logs: create, append.
    static func logsHandler(_ resource: Store) -> any LawSpec.Abilities.ExampleComposition.Logs {
        NativeLogs(store: logStore(resource))
    }

    struct NativeLogs: LawSpec.Abilities.ExampleComposition.Logs {
        let store: LogStore

        func create(_ log: String) { store.logs[log] = [] }

        func append(_ log: String, _ record: String) throws(Problem) -> Int64 {
            guard store.logs[log] != nil else { throw .unknownLog }
            if record.isEmpty { throw .emptyRecord }
            store.logs[log]!.append(record)
            return Int64(store.logs[log]!.count - 1)
        }
    }

    /// The native handler of Reader: size.
    static func readerHandler(_ resource: Store) -> any LawSpec.Abilities.ExampleComposition.Reader {
        NativeReader(store: logStore(resource))
    }

    struct NativeReader: LawSpec.Abilities.ExampleComposition.Reader {
        let store: LogStore

        func size(_ log: String) -> Int64? { store.logs[log].map { Int64($0.count) } }
    }

    /// The native handler of Writer: write, lastOffset.
    static func writerHandler(_ resource: Store) -> any LawSpec.Abilities.ExampleComposition.Writer {
        NativeWriter(store: logStore(resource))
    }

    final class NativeWriter: LawSpec.Abilities.ExampleComposition.Writer {
        let store: LogStore
        var last: Int64? = nil

        init(store: LogStore) { self.store = store }

        func write(_ log: String, _ record: String) -> Bool {
            guard store.logs[log] != nil, !record.isEmpty else { return false }
            store.logs[log]!.append(record)
            last = Int64(store.logs[log]!.count - 1)
            return true
        }

        func lastOffset() -> Int64? { last }
    }
}
