// Resources a law's cases use: acquired before a case and released after
// it, even when it fails, or shared across a unit's cases (`share R per
// unit`): acquired once, reset before each use, and released when the run
// ends. A resource that is not concurrent is used by one case at a time.
// ref:REQ-law-primitives ref:REQ-harness-units

import Foundation
import LawSpecRuntime

public enum Resources {
    private static func cleanupFailure(_ detail: String, _ inner: any Error) -> LawSpecError {
        let failure = LawSpecError("TestCleanupFailed", "\(detail): \(inner)", cause: "\(inner)")
        Harness.markHarnessFailure(failure)
        return failure
    }

    /// A resource for one case: the body's outcome stands unless releasing the
    /// resource fails, which fails the case.
    public static func withResource(_ acquire: () throws -> Value, _ release: (Value) throws -> Value, _ body: (Value) throws -> Value) throws -> Value {
        let value = try acquire()
        let outcome = Result { try body(value) }
        var cleanup: (any Error)? = nil
        do { _ = try release(value) } catch { cleanup = error }
        switch (outcome, cleanup) {
        case (.success(let result), nil): return result
        case (.failure(let e), nil): throw e
        case (.success, let c?): throw cleanupFailure("a resource's release failed", c)
        case (.failure(let e), let c?): throw cleanupFailure("a resource's release failed after the case failed (\(e))", c)
        }
    }

    private final class Shared: @unchecked Sendable {
        let acquire: () throws -> Value
        let reset: (Value) throws -> Value
        let release: (Value) throws -> Value
        let users: DispatchSemaphore?
        let gate = NSLock()
        var value: Value? = nil
        var leases = 0

        init(_ acquire: @escaping () throws -> Value, _ reset: @escaping (Value) throws -> Value, _ release: @escaping (Value) throws -> Value, _ concurrent: Bool) {
            self.acquire = acquire
            self.reset = reset
            self.release = release
            self.users = concurrent ? nil : DispatchSemaphore(value: 1)
        }

        func checkout() throws -> Value {
            users?.wait()
            gate.lock()
            defer { gate.unlock() }
            do {
                if let v = value {
                    if leases == 0 { _ = try reset(v) }
                } else {
                    value = try acquire()
                }
                leases += 1
                return value!
            } catch {
                users?.signal()
                throw error
            }
        }

        func checkin() {
            gate.lock()
            leases -= 1
            gate.unlock()
            users?.signal()
        }

        func releaseNow() throws {
            gate.lock()
            defer { gate.unlock() }
            if let v = value {
                value = nil
                _ = try release(v)
            }
        }
    }

    private static let shared = Locked([String: Shared]())

    private static let released: Void = {
        atexit {
            for (key, entry) in Resources.shared.with({ $0 }) {
                do { try entry.releaseNow() } catch {
                    FileHandle.standardError.write(Data("LawSpec: releasing the shared resource \(key) failed: \(error)\n".utf8))
                }
            }
        }
    }()

    /// A resource shared by a unit's cases.
    public static func withShared(_ key: String, _ acquire: @escaping () throws -> Value, _ reset: @escaping (Value) throws -> Value,
                                  _ release: @escaping (Value) throws -> Value, _ concurrent: Bool, _ body: (Value) throws -> Value) throws -> Value {
        _ = released
        let entry = shared.with { table -> Shared in
            if let found = table[key] { return found }
            let made = Shared(acquire, reset, release, concurrent)
            table[key] = made
            return made
        }
        let value = try entry.checkout()
        defer { entry.checkin() }
        return try body(value)
    }
}
