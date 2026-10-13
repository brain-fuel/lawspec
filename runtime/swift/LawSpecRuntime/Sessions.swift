// One protocol conversation: a pair of affine ends. Each step consumes an
// end and gives the next one, so a spent end fails. An end may be sent over
// another channel (delegation); on a network, an end that has not been used
// moves with its state, and a local one is relayed by its node.
// ref:DEC-sessions-by-construction ref:DEC-distribution-canonical-wire

import Foundation

/// What a protocol step carries: a value (with its wire descriptor text, if
/// it has one), or an end of another protocol.
public enum SessionPart: Sendable {
    case value(String?)
    case end(String)
}

/// A step of a protocol, as its first end sees it.
public struct SessionStep: Sendable {
    public let firstSends: Bool
    public let part: SessionPart

    public init(_ firstSends: Bool, _ part: SessionPart) {
        self.firstSends = firstSends
        self.part = part
    }
}

/// A protocol to open, with the catalogue of every protocol its steps name,
/// and the network deadline (ms) of its ends.
public struct SessionSpec: Sendable {
    public let id: String
    public let protocols: [String: [SessionStep]]
    public let deadline: Int

    public init(_ id: String, _ protocols: [String: [SessionStep]], _ deadline: Int) {
        self.id = id
        self.protocols = protocols
        self.deadline = deadline
    }

    func with(id: String) -> SessionSpec { SessionSpec(id, protocols, deadline) }
}

enum SessionItem {
    case item(Value)
    case delegated(SessionEnd)
}

/// A waiter for one item, settled once.
final class SessionWaiter: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<SessionItem, LawSpecError>?

    func settle(_ outcome: Result<SessionItem, LawSpecError>) {
        result = outcome
        done.signal()
    }

    func wait() -> Result<SessionItem, LawSpecError> {
        done.wait()
        return result!
    }
}

final class SideState {
    var generation: Int64
    var step = 0
    var closed = false
    var queue: [SessionItem] = []
    var reader: SessionWaiter?

    init(_ generation: Int64) { self.generation = generation }
}

public final class SessionChannel: @unchecked Sendable {
    private static let generations = Locked<Int64>(0)
    private static let custody = Locked<[ObjectIdentifier: SessionChannel]>([:])
    let gate = NSRecursiveLock()
    public let spec: SessionSpec
    let steps: [SessionStep]
    let network: (Node, Endpoint, Int)?
    private var sides: [SideState]

    static func fresh() -> Int64 { generations.with { $0 += 1; return $0 } }

    init(_ spec: SessionSpec, _ network: (Node, Endpoint, Int)?) {
        self.spec = spec
        steps = spec.protocols[spec.id] ?? []
        self.network = network
        sides = [SideState(SessionChannel.fresh()), SideState(SessionChannel.fresh())]
        if let (_, _, own) = network { sides[1 - own].step = steps.count }
    }

    static func fail(_ reason: String) -> LawSpecError { Fail.with("Session", reason) }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        gate.lock()
        defer { gate.unlock() }
        return try body()
    }

    func side(_ n: Int) -> SideState { sides[n] }

    func handle(_ n: Int) -> SessionEnd { SessionEnd(self, n, sides[n].generation, sides[n].step) }

    /// The ends of a new local channel.
    static func open(_ spec: SessionSpec) -> (SessionEnd, SessionEnd) {
        let channel = SessionChannel(spec, nil)
        return (channel.handle(0), channel.handle(1))
    }

    @discardableResult
    func check(_ e: SessionEnd) throws -> SideState {
        guard e.channel === self else { throw SessionChannel.fail("invalid_end") }
        let s = sides[e.side]
        if s.generation != e.generation || s.step != e.step { throw SessionChannel.fail("spent_end: this end was already used") }
        if s.closed { throw SessionChannel.fail("abandoned_end") }
        return s
    }

    func part(_ e: SessionEnd, _ sending: Bool) throws -> SessionPart {
        try locked {
            let s = try check(e)
            if s.step >= steps.count { throw SessionChannel.fail("protocol_complete") }
            let step = steps[s.step]
            let sends = e.side == 0 ? step.firstSends : !step.firstSends
            if sends != sending { throw SessionChannel.fail("wrong_step") }
            return step.part
        }
    }

    /// Check an end and give the next one.
    func advance(_ e: SessionEnd) throws -> SessionEnd {
        try locked {
            try check(e)
            sides[e.side].step += 1
            return handle(e.side)
        }
    }

    /// A new handle of an end, spending the old one (a transfer).
    func reissue(_ e: SessionEnd) throws -> SessionEnd {
        try locked {
            try check(e)
            sides[e.side].generation = SessionChannel.fresh()
            return handle(e.side)
        }
    }

    private func wake(_ n: Int) -> [() -> Void] {
        let s = sides[n]
        guard let reader = s.reader else { return [] }
        if !s.queue.isEmpty {
            s.reader = nil
            let item = s.queue.removeFirst()
            return [{ reader.settle(.success(item)) }]
        }
        if sides[1 - n].closed && network == nil {
            s.reader = nil
            s.closed = true
            return [{ reader.settle(.failure(SessionChannel.fail("peer_failed"))) }]
        }
        return []
    }

    func enqueue(_ n: Int, _ item: SessionItem) {
        let actions: [() -> Void] = locked {
            if sides[n].closed {
                if case .delegated(let e) = item { return [{ SessionChannel.discard(e) }] }
                return []
            }
            sides[n].queue.append(item)
            return wake(n)
        }
        for a in actions { a() }
    }

    /// Wait for the next item of a side.
    func await(_ n: Int) throws -> SessionItem {
        let reader = SessionWaiter()
        let actions: [() -> Void] = locked {
            sides[n].reader = reader
            return wake(n)
        }
        for a in actions { a() }
        return try reader.wait().get()
    }

    /// Close a side: its queue's delegated ends are discarded, and a local
    /// peer's reader learns the peer gave up.
    func closeSide(_ n: Int) {
        let actions: [() -> Void] = locked {
            let s = sides[n]
            if s.closed { return [] }
            s.closed = true
            var out = [() -> Void]()
            for item in s.queue { if case .delegated(let e) = item { out.append { SessionChannel.discard(e) } } }
            s.queue.removeAll()
            if let r = s.reader {
                s.reader = nil
                out.append { r.settle(.failure(SessionChannel.fail("abandoned_end"))) }
            }
            if network != nil { sides[1 - n].closed = true } else { out += wake(1 - n) }
            return out
        }
        SessionChannel.release(self)
        if let (_, endpoint, own) = network, own == n { endpoint.abandon() }
        for a in actions { a() }
    }

    /// Give up an end if it is still current (whoever holds it).
    static func discard(_ e: SessionEnd) {
        let current = e.channel.locked {
            let s = e.channel.sides[e.side]
            return s.generation == e.generation && !s.closed
        }
        if current { e.channel.closeSide(e.side) }
    }

    /// Queue custody is a forest: moving a channel's first end into another
    /// channel fails if it would make a cycle.
    static func move(_ child: SessionChannel, _ parent: SessionChannel) throws {
        try custody.with { c in
            var at: SessionChannel? = parent
            while let node = at {
                if node === child { throw SessionChannel.fail("cyclic_delegation") }
                at = c[ObjectIdentifier(node)]
            }
            c[ObjectIdentifier(child)] = parent
        }
    }

    static func release(_ child: SessionChannel) { custody.with { $0[ObjectIdentifier(child)] = nil } }
}

/// An end of a channel at a step. Using it spends it.
public final class SessionEnd: @unchecked Sendable, CustomStringConvertible {
    let channel: SessionChannel
    let side: Int
    let generation: Int64
    let step: Int

    init(_ channel: SessionChannel, _ side: Int, _ generation: Int64, _ step: Int) {
        self.channel = channel
        self.side = side
        self.generation = generation
        self.step = step
    }

    public var description: String { "session end \(side) of \(channel.spec.id) at step \(step)" }
}

/// The ends a task holds: given up if the task fails or is cancelled.
final class OwnedEnds: @unchecked Sendable {
    private let gate = NSLock()
    private var ends: [SessionEnd] = []

    init(_ ends: [SessionEnd]) { self.ends = ends }

    func add(_ e: SessionEnd) { gate.lock(); ends.append(e); gate.unlock() }

    func remove(_ e: SessionEnd) {
        gate.lock()
        ends.removeAll { $0.channel === e.channel && $0.side == e.side }
        gate.unlock()
    }

    /// Give up every end still held.
    func discardAll() {
        gate.lock()
        let held = ends
        gate.unlock()
        for e in held { SessionChannel.discard(e) }
    }
}

/// A task that runs a body with an end it was given; joined for its result.
public final class SessionTask: @unchecked Sendable {
    let owned: OwnedEnds
    private let done = DispatchSemaphore(value: 0)
    private var outcome: Result<Value, any Error>?

    init(_ owned: OwnedEnds) { self.owned = owned }

    func settle(_ result: Result<Value, any Error>) {
        outcome = result
        done.signal()
    }

    /// The result, waiting for it; at most `seconds` when given.
    func wait(_ seconds: Double?) -> Result<Value, any Error>? {
        if let seconds {
            guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        } else {
            done.wait()
        }
        done.signal()
        return outcome
    }
}

/// Session operations, as the generated typed ends call them.
/// ref:DEC-sessions-by-construction ref:DEC-async-native-tasks
public enum Sessions {
    private static let ownedKey = "lawspec.sessions.owned"

    /// Note that the running task now holds an end.
    @discardableResult
    private static func track(_ e: SessionEnd) -> SessionEnd {
        (Ambient.get(ownedKey) as? OwnedEnds)?.add(e)
        return e
    }

    /// Note that the running task no longer holds an end.
    private static func untrack(_ e: SessionEnd) { (Ambient.get(ownedKey) as? OwnedEnds)?.remove(e) }

    /// Run a body that owns some ends; if it fails, the ends it holds are given up.
    public static func withOwned<T>(_ ends: [SessionEnd], _ body: () throws -> T) throws -> T {
        let owned = OwnedEnds(ends)
        return try Ambient.with(ownedKey, owned) {
            do {
                return try body()
            } catch {
                owned.discardAll()
                throw error
            }
        }
    }

    /// Start a task with an end it now owns.
    public static func spawn(_ e: SessionEnd, _ body: @escaping @Sendable (SessionEnd) throws -> Value) throws -> SessionTask {
        let moved = try transfer(e)
        let task = SessionTask(OwnedEnds([moved]))
        LawThread.start {
            Ambient.set(ownedKey, task.owned)
            do {
                task.settle(.success(try body(moved)))
            } catch {
                task.owned.discardAll()
                task.settle(.failure(error))
            }
        }
        return task
    }

    /// Wait for a task's result; its failure is thrown here.
    public static func join(_ task: SessionTask) throws -> Value { try task.wait(nil)!.get() }

    /// Cancel a task: the ends it still owns are given up, so it stops at its next step.
    public static func cancel(_ task: SessionTask) {
        task.owned.discardAll()
        _ = task.wait(5)
    }

    private static let names = Locked<Int64>(0)
    private static let textType = Wire.textType

    private static func fail(_ reason: String) -> LawSpecError { SessionChannel.fail(reason) }

    private static func encode(_ part: SessionPart, _ value: Value) throws -> [UInt8] {
        switch part {
        case .value(.some(let text)):
            let (table, d) = try Descriptors.fromText(text)
            return try Descriptors.encode(d, value, table)
        case .value(.none): throw fail("non_wire_payload")
        case .end: return try Descriptors.encode(textType, value, [:])
        }
    }

    private static func decode(_ part: SessionPart, _ bytes: [UInt8]) throws -> Value {
        switch part {
        case .value(.some(let text)):
            let (table, d) = try Descriptors.fromText(text)
            return try Descriptors.decode(d, bytes, table)
        case .value(.none): throw fail("non_wire_payload")
        case .end: return try Descriptors.decode(textType, bytes, [:])
        }
    }

    /// A name no other session end on the node has.
    public static func freshName() -> String { "session-" + String(names.with { $0 += 1; return $0 }) }

    /// Whether every protocol a network end may carry has a wire form.
    public static func validate(_ spec: SessionSpec) throws {
        func go(_ id: String, _ seen: [String]) throws {
            if seen.contains(id) { return }
            let steps = spec.protocols[id] ?? []
            if steps.isEmpty { throw fail("empty_network_protocol") }
            for step in steps {
                switch step.part {
                case .end(let other): try go(other, [id] + seen)
                case .value(.none): throw fail("non_wire_payload")
                case .value(.some(let text)): _ = try Descriptors.fromText(text)
                }
            }
        }
        try go(spec.id, [])
    }

    /// A new local channel's two ends.
    public static func openPair(_ spec: SessionSpec) -> (SessionEnd, SessionEnd) { SessionChannel.open(spec) }

    /// A channel end on a node over the network, connected to a peer's
    /// address if given.
    public static func networkStart(_ spec: SessionSpec, _ node: Node, _ name: String, _ side: Int, _ connection: String?) throws -> SessionEnd {
        try validate(spec)
        let endpoint = try Endpoint(node, name, spec.deadline)
        let channel = SessionChannel(spec, (node, endpoint, side))
        let e = channel.handle(side)
        do {
            if let peer = connection { try endpoint.connect(peer) }
            return track(e)
        } catch {
            endpoint.stop()
            throw error
        }
    }

    /// Listen on a node: the first end, at its address.
    public static func listen(_ node: Node, _ name: String, _ spec: SessionSpec) throws -> SessionEnd {
        try networkStart(spec, node, name, 0, nil)
    }

    /// Dial a listening end: the second end.
    public static func dial(_ node: Node, _ address: String, _ spec: SessionSpec) throws -> SessionEnd {
        try networkStart(spec, node, freshName(), 1, address)
    }

    private static func endpointOf(_ e: SessionEnd) throws -> Endpoint {
        try e.channel.locked { _ = try e.channel.check(e) }
        guard let (_, endpoint, _) = e.channel.network else { throw fail("local_end") }
        return endpoint
    }

    /// A network end's address.
    public static func address(_ e: SessionEnd) throws -> String { try endpointOf(e).address }

    /// Send a value; the next end.
    public static func send(_ e: SessionEnd, _ value: Value) throws -> SessionEnd {
        let channel = e.channel
        let part = try channel.part(e, true)
        if case .end = part { throw fail("expected_delegation") }
        if let (_, endpoint, _) = channel.network {
            let bytes = try encode(part, value)
            let next = try channel.advance(e)
            try endpoint.send(bytes)
            untrack(e)
            return track(next)
        }
        let next = try channel.advance(e)
        channel.enqueue(1 - e.side, .item(value))
        untrack(e)
        return track(next)
    }

    private static func failedPeer(_ channel: SessionChannel, _ side: Int, _ reason: String) -> LawSpecError {
        channel.closeSide(side)
        return fail("peer_failed " + reason)
    }

    /// Receive a value; it and the next end.
    public static func receiveValue(_ e: SessionEnd) throws -> (Value, SessionEnd) {
        let channel = e.channel
        let part = try channel.part(e, false)
        if case .end = part { throw fail("wrong_receive_kind") }
        let next = try channel.advance(e)
        untrack(e)
        track(next)
        if let (_, endpoint, _) = channel.network {
            switch try endpoint.receive(channel.spec.deadline) {
            case .success(let bytes):
                guard let value = try? decode(part, bytes) else { throw failedPeer(channel, e.side, "invalid_payload") }
                return (value, next)
            case .failure(let reason):
                throw failedPeer(channel, e.side, reason.reason)
            }
        }
        switch try channel.await(e.side) {
        case .item(let value): return (value, next)
        case .delegated: throw fail("wrong_receive_kind")
        }
    }

    /// Give up an end.
    public static func abandon(_ e: SessionEnd) throws {
        try e.channel.locked { _ = try e.channel.check(e) }
        e.channel.closeSide(e.side)
        untrack(e)
    }

    /// The protocol an end follows.
    public static func specification(_ e: SessionEnd) -> SessionSpec { e.channel.spec }

    /// Move an end to another holder: the old handle is spent.
    public static func transfer(_ e: SessionEnd) throws -> SessionEnd {
        let moved = try e.channel.reissue(e)
        untrack(e)
        return moved
    }

    private static func unusedFirst(_ e: SessionEnd, _ expected: String) throws {
        try e.channel.locked { _ = try e.channel.check(e) }
        if e.side != 0 || e.step != 0 { throw fail("not_an_unused_first_end") }
        if e.channel.spec.id != expected { throw fail("different_protocol") }
    }

    /// The address a delegated end is reached at from another node: a network
    /// end moves (its offer); a local end stays, and this node relays it.
    public static func offer(_ node: Node, _ e: SessionEnd, _ expected: String) throws -> String {
        try unusedFirst(e, expected)
        guard let (_, endpoint, _) = e.channel.network else { return try relay(node, e) }
        let address = try endpoint.offer()
        // The end now belongs to its taker: spend this handle without abandoning.
        e.channel.locked {
            let s = e.channel.side(e.side)
            s.generation = -s.generation
            s.closed = true
        }
        untrack(e)
        return address
    }

    private static func relay(_ node: Node, _ e: SessionEnd) throws -> String {
        let spec = e.channel.spec
        try validate(spec)
        let remote = try networkStart(spec, node, freshName(), 1, nil)
        let addressOfRemote = try address(remote)
        let local = try transfer(e)
        let remoteMoved = try transfer(remote)
        let steps = spec.protocols[spec.id] ?? []
        LawThread.start {
            var l = local
            var r = remoteMoved
            do {
                for step in steps {
                    switch (step.firstSends, step.part) {
                    case (true, .value):
                        let (v, next) = try receiveValue(r)
                        r = next
                        l = try send(l, v)
                    case (false, .value):
                        let (v, next) = try receiveValue(l)
                        l = next
                        r = try send(r, v)
                    case (true, .end):
                        let (v, next) = try receiveEnd(r)
                        r = next
                        l = try sendEnd(l, v)
                    case (false, .end):
                        let (v, next) = try receiveEnd(l)
                        l = next
                        r = try sendEnd(r, v)
                    }
                }
            } catch {
                SessionChannel.discard(l)
                SessionChannel.discard(r)
            }
        }
        return addressOfRemote
    }

    /// The end a delegation's address names, taken on this node.
    public static func take(_ node: Node, _ address: String, _ spec: SessionSpec) throws -> SessionEnd {
        let moving = address.contains("?take=")
        let e = try networkStart(spec, node, freshName(), 0, moving ? nil : address)
        do {
            if moving { try endpointOf(e).take(address) }
            return e
        } catch {
            try? abandon(e)
            throw error
        }
    }

    /// Send an unused first end of another protocol; the next end.
    public static func sendEnd(_ e: SessionEnd, _ other: SessionEnd) throws -> SessionEnd {
        let channel = e.channel
        guard case .end(let expected) = try channel.part(e, true) else { throw fail("expected_value") }
        if other.side != 0 || other.step != 0 { throw fail("not_an_unused_first_end") }
        if other.channel === channel { throw fail("cyclic_delegation") }
        if let (node, endpoint, _) = channel.network {
            let addressText = try offer(node, other, expected)
            let next = try channel.advance(e)
            try endpoint.send(try encode(.end(expected), .text(addressText)))
            untrack(e)
            return track(next)
        }
        try unusedFirst(other, expected)
        try SessionChannel.move(other.channel, channel)
        let moved = try transfer(other)
        let next = try channel.advance(e)
        channel.enqueue(1 - e.side, .delegated(moved))
        untrack(e)
        return track(next)
    }

    /// Receive an end; it and the next end.
    public static func receiveEnd(_ e: SessionEnd) throws -> (SessionEnd, SessionEnd) {
        let channel = e.channel
        guard case .end(let proto) = try channel.part(e, false) else { throw fail("wrong_receive_kind") }
        let next = try channel.advance(e)
        untrack(e)
        track(next)
        if let (node, endpoint, _) = channel.network {
            switch try endpoint.receive(channel.spec.deadline) {
            case .success(let bytes):
                guard case .text(let addressText)? = try? decode(.end(proto), bytes) else {
                    throw failedPeer(channel, e.side, "invalid_payload")
                }
                do {
                    return (track(try take(node, addressText, channel.spec.with(id: proto))), next)
                } catch {
                    throw failedPeer(channel, e.side, Node.message(error))
                }
            case .failure(let reason):
                throw failedPeer(channel, e.side, reason.reason)
            }
        }
        switch try channel.await(e.side) {
        case .delegated(let other):
            SessionChannel.release(other.channel)
            return (track(other), next)
        case .item:
            throw fail("wrong_receive_kind")
        }
    }
}
