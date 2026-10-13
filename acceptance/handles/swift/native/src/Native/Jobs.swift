import Foundation

public enum Work {
    /// The application's job queue, shared between threads.
    public final class Jobs: @unchecked Sendable {
        private var queue = [Int32]()
        private let gate = NSLock()

        public init() {}

        public func submit(_ job: Int32) {
            gate.lock()
            defer { gate.unlock() }
            queue.append(job)
        }

        public func take() -> Int32? {
            gate.lock()
            defer { gate.unlock() }
            return queue.isEmpty ? nil : queue.removeFirst()
        }

        public func pending() -> Int32 {
            gate.lock()
            defer { gate.unlock() }
            return Int32(queue.count)
        }
    }
}
