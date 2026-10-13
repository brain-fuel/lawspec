// A typed mailbox of portable values. Native conversion runs in the caller;
// the queue never runs application code. Closing refuses new sends and lets
// accepted values drain. A served mailbox belongs to its node, and a remote
// send completes once the mailbox has the value.
// ref:DEC-actors-otp-supervision ref:DEC-distribution-canonical-wire

import Foundation

public final class Mailbox: NodeService, @unchecked Sendable {
    private final class Waiter {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Value, LawSpecError>?
    }

    private struct State {
        var queue: [Value] = []
        var closed = false
        var stopped = false
        var reader: Waiter?
    }

    private let network: (Node, String, Descriptors.Table, Descriptors.Descriptor)?
    private let state = Locked(State())
    private var served: String?

    private static func fail(_ reason: String) -> LawSpecError { Fail.with("Mailbox", reason) }

    /// A local mailbox.
    public init() { network = nil }

    private init(_ node: Node, _ name: String, _ table: Descriptors.Table, _ d: Descriptors.Descriptor) throws {
        network = (node, name, table, d)
        let box = Locked<Mailbox?>(nil)
        served = try node.registerReceiver(name) { frame in box.with { $0 }?.incoming(frame) }
        box.with { $0 = self }
        node.adopt(self)
    }

    /// A mailbox served at a name on a node, of values of a descriptor text.
    public static func serve(_ node: Node, _ name: String, _ descriptor: String) throws -> Mailbox {
        let (table, d) = try Descriptors.fromText(descriptor)
        return try Mailbox(node, name, table, d)
    }

    private func incoming(_ frame: Frame) {
        guard let (node, _, table, d) = network else { return }
        let (status, body): (Int, String)
        if state.with({ $0.closed }) {
            (status, body) = (2, "the mailbox is closed")
        } else if frame.kind != "mail" {
            (status, body) = (3, "not a mailbox request")
        } else if let value = try? Descriptors.decode(d, frame.payload, table) {
            enqueue(value)
            (status, body) = (0, "")
        } else {
            (status, body) = (3, "not a message of this mailbox")
        }
        if frame.id != 0 { try? node.reply(frame.source, frame.id, status, Array(body.utf8)) }
    }

    private func enqueue(_ value: Value) {
        let waiting: Waiter? = state.with { s in
            if let r = s.reader {
                s.reader = nil
                return r
            }
            s.queue.append(value)
            return nil
        }
        if let r = waiting {
            r.result = .success(value)
            r.done.signal()
        }
    }

    /// The served mailbox's address.
    public func address() throws -> String {
        guard let served else { throw Mailbox.fail("local_mailbox") }
        return served
    }

    /// Add a value, unless the mailbox is closed.
    public func send(_ value: Value) throws {
        try state.with { s in if s.closed || s.stopped { throw Mailbox.fail("closed") } }
        enqueue(value)
    }

    /// The next value, waiting until a deadline (seconds from now) or for
    /// ever: nil when the time passed.
    private func wait(_ seconds: Double?) throws -> Value? {
        let pending: Either = try state.with { s in
            if s.reader != nil { throw Mailbox.fail("already_receiving") }
            if !s.queue.isEmpty { return .value(s.queue.removeFirst()) }
            if s.closed || s.stopped { throw Mailbox.fail("closed") }
            let r = Waiter()
            s.reader = r
            return .waiter(r)
        }
        guard case .waiter(let r) = pending else {
            if case .value(let v) = pending { return v }
            return nil
        }
        let finished: Bool
        if let seconds {
            finished = seconds > 0 && r.done.wait(timeout: .now() + seconds) == .success
        } else {
            r.done.wait()
            finished = true
        }
        if !finished {
            let raced: Bool = state.with { s in
                if let current = s.reader, current === r {
                    s.reader = nil
                    return false
                }
                return true
            }
            if !raced { return nil }
            r.done.wait()
        }
        return try r.result!.get()
    }

    private enum Either {
        case value(Value)
        case waiter(Waiter)
    }

    /// The next value, waiting for one.
    public func receive() throws -> Value {
        guard let value = try wait(nil) else { throw Mailbox.fail("closed") }
        return value
    }

    /// The next value within some microseconds, or none (a Maybe).
    public func receiveWithin(_ micros: BigInt) throws -> Value {
        let seconds = max(0, micros.doubleValue) / 1_000_000
        if let value = try wait(seconds) { return .data("Maybe::Just", [value]) }
        return .data("Maybe::Nothing", [])
    }

    /// The next value within a time, or nil.
    public func receive(within timeout: Duration) throws -> Value? { try wait(max(0, Timeouts.seconds(timeout))) }

    private func settle(_ r: Waiter?) {
        if let r {
            r.result = .failure(Mailbox.fail("closed"))
            r.done.signal()
        }
    }

    /// Refuse new values; accepted ones still drain.
    public func close() {
        settle(state.with { s in
            s.closed = true
            guard s.queue.isEmpty else { return nil }
            let r = s.reader
            s.reader = nil
            return r
        })
    }

    public func release() { stop() }

    /// Stop the mailbox: a waiting reader fails, and a served one leaves its node.
    public func stop() {
        settle(state.with { s in
            s.stopped = true
            let r = s.reader
            s.reader = nil
            return r
        })
        if let (node, name, _, _) = network { node.unregister(name) }
    }
}

/// Sending to a mailbox on another node.
public final class MailboxSender: Sendable {
    private let node: Node
    private let address: String
    private let table: Descriptors.Table
    private let descriptor: Descriptors.Descriptor
    private let timeout: Int

    public init(_ node: Node, _ address: String, _ descriptor: String, _ timeout: Int) throws {
        if timeout <= 0 { throw Fail.with("Mailbox", "invalid_sender") }
        self.node = node
        self.address = address
        (table, self.descriptor) = try Descriptors.fromText(descriptor)
        self.timeout = timeout
    }

    /// Send, waiting until the mailbox has the value.
    public func send(_ value: Value) throws {
        let (status, body) = try node.request(address, "mail", try Descriptors.encode(descriptor, value, table), timeout)
        switch status {
        case 0: return
        case 2: throw Fail.with("Mailbox", "closed")
        default: throw Fail.with("Mailbox", "remote \(status) " + String(decoding: body, as: UTF8.self))
        }
    }
}

/// Mailboxes, as generated code opens and uses them.
public enum Mailboxes {
    public static func open() -> Mailbox { Mailbox() }

    /// A mailbox for a body, stopped after it.
    public static func withMailbox<T>(_ body: (Mailbox) throws -> T) rethrows -> T {
        let box = Mailbox()
        defer { box.stop() }
        return try body(box)
    }

    public static func serve(_ node: Node, _ name: String, _ descriptor: String) throws -> Mailbox { try Mailbox.serve(node, name, descriptor) }

    public static func connect(_ node: Node, _ address: String, _ descriptor: String, _ timeout: Int) throws -> MailboxSender {
        try MailboxSender(node, address, descriptor, timeout)
    }
}

/// LawSpec Durations as the waits the network and mailboxes take.
public enum Timeouts {
    /// A duration in seconds.
    public static func seconds(_ d: Duration) -> Double {
        let (s, atto) = d.components
        return Double(s) + Double(atto) / 1e18
    }

    /// A duration in whole milliseconds, at least 0.
    public static func milliseconds(_ d: Duration) -> Int {
        let (s, atto) = d.components
        return max(0, Int(s) * 1000 + Int(atto / 1_000_000_000_000_000))
    }
}
