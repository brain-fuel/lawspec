// Actors and supervision trees. A handle names a stable mailbox, not a
// worker: a supervised restart replaces the worker and keeps the committed
// checkpoint and the messages waiting. Each actor handles one message at a
// time on a thread of its own; a handler that returns commits its next state
// before the reply, and one that throws commits nothing. Supervisors restart
// their children by strategy (one for one, one for all, rest for one) and
// lifetime (permanent, transient, temporary) within a rolling restart budget,
// and escalate to their own supervisor when it is spent. Calls block their
// caller, as the synchronous runtime's every call does.
// ref:DEC-actors-otp-supervision ref:erlang-otp-supervisors

import Foundation

public enum Actors {
    /// When a supervisor restarts a child that stopped.
    public enum Lifetime: Sendable {
        /// Always.
        case permanent
        /// Only after a crash.
        case transient
        /// Never.
        case temporary
    }

    /// Which children a supervisor restarts when one fails.
    public enum Strategy: Sendable {
        case oneForOne
        case oneForAll
        case restForOne
    }

    /// What a tree runs: an actor (its start and its restart from the last
    /// checkpoint) or a supervisor of named children.
    public indirect enum Spec: @unchecked Sendable {
        case actor(start: () throws -> Any, restart: (Any) throws -> Any)
        case supervisor(strategy: Strategy, restarts: Int, periodMicros: Int64, children: [(String, Lifetime, Spec)])

        var isActor: Bool {
            if case .actor = self { return true }
            return false
        }
    }

    /// What an observer is told about a handle.
    public enum Event: @unchecked Sendable {
        case crashed(any Error)
        case stopped
    }

    /// A reply slot, settled once.
    final class Reply: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let result = Locked<Result<Any, any Error>?>(nil)

        func settle(_ outcome: Result<Any, any Error>) {
            let first: Bool = result.with { r in
                if r != nil { return false }
                r = outcome
                return true
            }
            if first { done.signal() }
        }

        func wait() throws -> Any {
            done.wait()
            return try result.with { $0 }!.get()
        }
    }

    enum Operation {
        case run((Any) throws -> (Any, Any))
        case crash(any Error, ObjectIdentifier)
        case restart
        case stop
    }

    struct Entry {
        let reply: Reply?
        let operation: Operation
    }

    /// A mailbox of events from the handles it monitors, received selectively.
    public final class Inbox: @unchecked Sendable {
        private var events: [(Handle, Event)] = []
        private let condition = NSCondition()

        public init() {}

        func post(_ handle: Handle, _ event: Event) {
            condition.lock()
            events.append((handle, event))
            condition.broadcast()
            condition.unlock()
        }

        /// The next event of a handle, waiting at most a number of milliseconds.
        public func receive(_ handle: Handle, _ milliseconds: Int) -> Event? {
            let deadline = Date().addingTimeInterval(Double(milliseconds) / 1000)
            condition.lock()
            defer { condition.unlock() }
            while true {
                if let i = events.firstIndex(where: { $0.0 == handle }) { return events.remove(at: i).1 }
                if Date() >= deadline { return nil }
                _ = condition.wait(until: deadline)
            }
        }
    }

    final class TreeNode {
        let path: [String]
        let spec: Spec
        let parent: [String]?
        let lifetime: Lifetime
        var children: [(String, [String])] = []
        var state: Any = ()
        var checkpoint: Any?
        /// Run start, or restart from the checkpoint, before the next message.
        var initial = false
        var worker = 0
        /// Which incarnation of the worker runs: a restart makes a new one.
        var incarnation = 0
        var waiting: [Entry] = []
        var active: Entry?
        var running = false
        var accepting = true
        var removed = false
        var observers: [Inbox] = []
        var links: [Handle] = []
        var seen = Set<ObjectIdentifier>()
        var restarts: [Int64] = []
        var stopNotified = false

        init(_ path: [String], _ spec: Spec, _ parent: [String]?, _ lifetime: Lifetime) {
            self.path = path
            self.spec = spec
            self.parent = parent
            self.lifetime = lifetime
        }

        var isActor: Bool { spec.isActor }
    }

    /// The tree of one started spec: its nodes, under one lock. No
    /// application code runs under the lock.
    final class Tree: @unchecked Sendable {
        let gate = NSRecursiveLock()
        var nodes: [[String]: TreeNode] = [:]

        func locked<T>(_ body: () throws -> T) rethrows -> T {
            gate.lock()
            defer { gate.unlock() }
            return try body()
        }
    }

    /// A stable handle on an actor or a supervisor of a tree.
    public struct Handle: Sendable, Equatable, CustomStringConvertible {
        let tree: Tree
        let path: [String]

        public static func == (a: Handle, b: Handle) -> Bool { a.tree === b.tree && a.path == b.path }

        public var description: String { "actor " + path.joined(separator: "/") }
    }

    /// An origin of a crash, by identity.
    private final class Origin {}

    private static let currentKey = "lawspec.actors.current"

    private static func now() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1000) }

    private static func stoppedError() -> any Error { Fail.with("ActorStopped", "the actor has stopped") }

    private static func crashedError(_ cause: any Error) -> any Error {
        LawSpecError("ActorCrashed", Node.message(cause), cause: String(describing: cause))
    }

    private static func reply(_ entry: Entry, _ result: Result<Any, any Error>) { entry.reply?.settle(result) }

    private static func node(_ tree: Tree, _ path: [String]) -> TreeNode { tree.nodes[path]! }

    private static func descendants(_ tree: Tree, _ path: [String]) -> [[String]] {
        [path] + node(tree, path).children.flatMap { descendants(tree, $0.1) }
    }

    private static func notify(_ tree: Tree, _ n: TreeNode, _ event: Event) {
        for inbox in n.observers { inbox.post(Handle(tree: tree, path: n.path), event) }
    }

    /// Mark a subtree gone: every waiting caller is told the actor stopped.
    private static func halt(_ tree: Tree, _ path: [String]) {
        for p in descendants(tree, path).reversed() {
            let n = node(tree, p)
            if n.removed { continue }
            if let e = n.active { reply(e, .failure(stoppedError())) }
            for e in n.waiting { reply(e, .failure(stoppedError())) }
            n.waiting.removeAll()
            if !n.stopNotified { notify(tree, n, .stopped) }
            n.removed = true
            n.accepting = false
            n.active = nil
            n.stopNotified = true
            n.worker += 1
        }
    }

    private static func schedule(_ tree: Tree, _ n: TreeNode) {
        guard !n.running, !n.removed, n.isActor, n.initial || !n.waiting.isEmpty else { return }
        n.running = true
        let generation = n.worker
        let box = UncheckedBox(n)
        LawThread.start { pump(tree, box.value, generation) }
    }

    /// A supervisor restarts a group of its children: the failed actor starts
    /// again from its checkpoint before its next message; every other actor
    /// restarts after the messages it had already accepted.
    private static func restartGroup(_ tree: Tree, _ parent: [String], _ failed: [String], _ origin: [String]) {
        let supervisor = node(tree, parent)
        let live = supervisor.children.map(\.1).filter { !node(tree, $0).removed }
        let group: [[String]]
        switch supervisor.spec {
        case .supervisor(.oneForAll, _, _, _): group = live
        case .supervisor(.restForOne, _, _, _): group = Array(live.drop(while: { $0 != failed }))
        default: group = [failed]
        }
        for member in group {
            if node(tree, member).lifetime == .temporary {
                halt(tree, member)
                continue
            }
            for p in descendants(tree, member) {
                let n = node(tree, p)
                if n.removed { continue }
                n.accepting = true
                n.incarnation += 1
                if n.isActor {
                    if p == origin { n.initial = true } else { n.waiting.append(Entry(reply: nil, operation: .restart)) }
                    schedule(tree, n)
                } else {
                    n.restarts = []
                }
            }
        }
    }

    /// Decide what a stop (normal) or crash (abnormal) means: a restart
    /// within the parent's budget, an escalation, or the end of the subtree.
    private static func decide(_ tree: Tree, _ path: [String], _ abnormal: Bool, _ origin: [String]) {
        let n = node(tree, path)
        let restart = !n.removed && (n.lifetime == .permanent || (n.lifetime == .transient && abnormal))
        if let parent = n.parent, restart {
            let supervisor = node(tree, parent)
            guard case .supervisor(_, let limit, let period, _) = supervisor.spec else {
                halt(tree, path)
                return
            }
            let at = now()
            let recent = supervisor.restarts.filter { at - $0 <= period }
            if recent.count < limit && !supervisor.removed {
                supervisor.restarts = recent + [at]
                restartGroup(tree, parent, path, origin)
            } else {
                decide(tree, parent, true, origin)
            }
            return
        }
        if !n.isActor && abnormal {
            notify(tree, n, .crashed(Fail.with("RestartLimit", path.joined(separator: "/"))))
            n.stopNotified = true
        }
        halt(tree, path)
    }

    /// An actor failed: its caller learns why, its observers and linked
    /// actors are told, and its supervisor decides.
    private static func failed(_ tree: Tree, _ n: TreeNode, _ entry: Entry?, _ cause: any Error, _ origin: ObjectIdentifier) -> [Handle] {
        if let e = entry {
            if case .crash = e.operation { reply(e, .success(())) } else { reply(e, .failure(crashedError(cause))) }
        }
        n.active = nil
        n.seen.insert(origin)
        notify(tree, n, .crashed(cause))
        n.stopNotified = true
        let links = n.links
        decide(tree, n.path, true, n.path)
        if !n.removed { n.stopNotified = false }
        return links
    }

    private static func propagate(_ links: [Handle], _ cause: any Error, _ origin: ObjectIdentifier) {
        for other in links {
            let t = other.tree
            t.locked {
                guard let n = t.nodes[other.path], n.accepting, !n.removed, !n.seen.contains(origin) else { return }
                n.seen.insert(origin)
                n.waiting.append(Entry(reply: nil, operation: .crash(cause, origin)))
                schedule(t, n)
            }
        }
    }

    private enum Step {
        case initialize(Any?)
        case message(Entry)
    }

    private static func pump(_ tree: Tree, _ n: TreeNode, _ generation: Int) {
        while true {
            let originObject = Origin()
            let origin = ObjectIdentifier(originObject)
            let step: Step? = tree.locked {
                if n.worker != generation || n.removed {
                    if n.worker == generation { n.running = false }
                    return nil
                }
                if n.initial { return .initialize(n.checkpoint) }
                if !n.waiting.isEmpty {
                    let e = n.waiting.removeFirst()
                    n.active = e
                    return .message(e)
                }
                n.running = false
                return nil
            }
            guard let step else { return }
            guard case .actor(let start, let restart) = n.spec else { return }
            switch step {
            case .initialize(let checkpoint):
                let outcome = Result { try checkpoint.map(restart) ?? start() }
                let links: [Handle] = tree.locked {
                    if n.worker != generation { return [] }
                    switch outcome {
                    case .success(let v):
                        n.state = v
                        n.checkpoint = v
                        n.initial = false
                        return []
                    case .failure(let e):
                        return failed(tree, n, nil, e, origin)
                    }
                }
                if case .failure(let e) = outcome, !links.isEmpty { propagate(links, e, origin) }
            case .message(let entry):
                let state = tree.locked { n.state }
                func run(_ body: () throws -> (Any, Any)) -> Result<(Any, Any), any Error> {
                    Thread.current.threadDictionary[currentKey] = UncheckedBox(n)
                    defer { Thread.current.threadDictionary[currentKey] = nil }
                    return Result { try body() }
                }
                switch entry.operation {
                case .stop:
                    tree.locked {
                        if n.worker == generation {
                            n.active = nil
                            reply(entry, .success(()))
                            decide(tree, n.path, false, n.path)
                        }
                    }
                case .crash(let cause, let crashOrigin):
                    let links: [Handle] = tree.locked { n.worker == generation ? failed(tree, n, entry, cause, crashOrigin) : [] }
                    propagate(links, cause, crashOrigin)
                case .run(let handler):
                    let outcome = run { try handler(state) }
                    commit(tree, n, generation, entry, outcome, origin, answer: true)
                case .restart:
                    let outcome = run { ((), try restart(state)) }
                    commit(tree, n, generation, entry, outcome, origin, answer: false)
                }
            }
        }
    }

    private static func commit(_ tree: Tree, _ n: TreeNode, _ generation: Int, _ entry: Entry, _ outcome: Result<(Any, Any), any Error>,
                               _ origin: ObjectIdentifier, answer: Bool) {
        let links: [Handle] = tree.locked {
            if n.worker != generation { return [] }
            switch outcome {
            case .success(let (reply, next)):
                n.state = next
                n.checkpoint = next
                n.active = nil
                if answer { Actors.reply(entry, .success(reply)) }
                return []
            case .failure(let e):
                return failed(tree, n, entry, e, origin)
            }
        }
        if case .failure(let e) = outcome, !links.isEmpty { propagate(links, e, origin) }
    }

    // MARK: Specs

    /// An actor: its state's start, and its state after a crash from the
    /// last committed one.
    public static func actor(_ start: @escaping () throws -> Any, _ restart: @escaping (Any) throws -> Any) -> Spec {
        .actor(start: start, restart: restart)
    }

    /// An actor whose state after a crash is a fresh start.
    public static func actorOf(_ start: @escaping () throws -> Any) -> Spec { .actor(start: start, restart: { _ in try start() }) }

    /// A supervisor: its strategy, at most a number of restarts within a
    /// period (microseconds), and its children in start order, each named
    /// and with its lifetime.
    public static func supervisor(_ strategy: Strategy, _ restarts: Int, _ periodMicros: Int64, _ children: [(String, Lifetime, Spec)]) throws -> Spec {
        if restarts < 0 || periodMicros <= 0 {
            throw Fail.with("InvalidSupervisor", "a supervisor needs restarts >= 0 and a positive period")
        }
        if Set(children.map(\.0)).count != children.count { throw Fail.with("InvalidSupervisor", "duplicate child names") }
        return .supervisor(strategy: strategy, restarts: restarts, periodMicros: periodMicros, children: children)
    }

    // MARK: Starting and stopping trees

    private static func allocate(_ tree: Tree, _ path: [String], _ spec: Spec, _ parent: [String]?, _ lifetime: Lifetime) {
        let n = TreeNode(path, spec, parent, lifetime)
        tree.nodes[path] = n
        switch spec {
        case .supervisor(_, _, _, let children):
            n.children = children.map { ($0.0, path + [$0.0]) }
            for (name, life, child) in children { allocate(tree, path + [name], child, path, life) }
        case .actor:
            n.initial = true
        }
    }

    /// Stop a handle: an actor finishes the messages it accepted first; a
    /// supervisor stops its whole subtree. Stopping a stopped handle does nothing.
    public static func stop(_ handle: Handle) {
        let tree = handle.tree
        let wait: Reply? = tree.locked {
            let n = node(tree, handle.path)
            if n.removed { return nil }
            if n.isActor {
                n.accepting = n.parent != nil && n.lifetime == .permanent
                let r = Reply()
                n.waiting.append(Entry(reply: r, operation: .stop))
                schedule(tree, n)
                return r
            }
            if n.parent != nil && n.lifetime == .permanent { decide(tree, handle.path, false, handle.path) } else { halt(tree, handle.path) }
            return nil
        }
        _ = try? wait?.wait()
    }

    /// Start a spec. Its actors start in order; a start that fails stops the
    /// tree and fails here. An actor alone runs as the temporary child of a
    /// supervisor with no restarts; its handle is the actor's.
    public static func start(_ spec: Spec) throws -> Handle {
        let tree = Tree()
        let root: Spec
        let visible: [String]
        if spec.isActor {
            root = .supervisor(strategy: .oneForOne, restarts: 0, periodMicros: 1, children: [("actor", .temporary, spec)])
            visible = ["actor"]
        } else {
            root = spec
            visible = []
        }
        tree.locked { allocate(tree, [], root, nil, .permanent) }
        let actors = tree.locked { descendants(tree, []).map { node(tree, $0) }.filter(\.isActor) }
        for n in actors {
            guard case .actor(let start, _) = n.spec else { continue }
            let value: Any
            do {
                value = try start()
            } catch {
                tree.locked { halt(tree, []) }
                throw LawSpecError("ActorStartFailed", Node.message(error), cause: String(describing: error))
            }
            tree.locked {
                n.state = value
                n.checkpoint = value
                n.initial = false
            }
        }
        return Handle(tree: tree, path: visible)
    }

    /// Run a body with a started spec, stopping its tree afterwards.
    public static func withSpec<T>(_ spec: Spec, _ body: (Handle) throws -> T) throws -> T {
        let handle = try start(spec)
        defer { stop(Handle(tree: handle.tree, path: [])) }
        return try body(handle)
    }

    // MARK: Messages

    /// The reply of a queued message; refused at once when the actor stopped.
    private static func enqueue(_ handle: Handle, _ operation: Operation, _ wait: Bool) throws -> Reply {
        let tree = handle.tree
        return try tree.locked {
            let n = node(tree, handle.path)
            if wait, let current = Thread.current.threadDictionary[currentKey] as? UncheckedBox<TreeNode>, current.value === n {
                throw Fail.with("ActorSelfCall", "an actor cannot call itself")
            }
            if !n.isActor || !n.accepting || n.removed { throw stoppedError() }
            let r = Reply()
            n.waiting.append(Entry(reply: r, operation: operation))
            schedule(tree, n)
            return r
        }
    }

    /// Send a handler and wait for its reply. The handler gets the state and
    /// gives the reply and the next state.
    public static func call(_ handle: Handle, _ handler: @escaping (Any) throws -> (Any, Any)) throws -> Any {
        try enqueue(handle, .run(handler), true).wait()
    }

    /// Send a handler without waiting for it.
    public static func tell(_ handle: Handle, _ handler: @escaping (Any) throws -> (Any, Any)) throws {
        _ = try enqueue(handle, .run(handler), false)
    }

    /// The actor's committed state.
    public static func state(_ handle: Handle) throws -> Any { try call(handle) { ($0, $0) } }

    /// Crash the actor in order with its messages, as a failing handler would.
    public static func crash(_ handle: Handle) throws {
        let origin = Origin()
        _ = try enqueue(handle, .crash(Fail.with("CrashedOnPurpose"), ObjectIdentifier(origin)), true).wait()
    }

    /// Kill the actor's worker now, as an external failure: a handler it is
    /// running commits nothing and its caller learns the actor crashed; the
    /// messages waiting run after its supervisor restarts it.
    public static func kill(_ handle: Handle) {
        let tree = handle.tree
        let originObject = Origin()
        let origin = ObjectIdentifier(originObject)
        let cause = Fail.with("ActorKilled", "the actor's worker was killed")
        let links: [Handle]? = tree.locked {
            let n = node(tree, handle.path)
            if n.removed || !n.isActor { return nil }
            n.worker += 1
            n.incarnation += 1
            n.running = false
            let links = failed(tree, n, n.active, cause, origin)
            schedule(tree, n)
            return links
        }
        if let links { propagate(links, cause, origin) }
    }

    /// A supervisor's child by name (stable across restarts).
    public static func child(_ handle: Handle, _ name: String) throws -> Handle {
        try handle.tree.locked {
            guard let (_, path) = node(handle.tree, handle.path).children.first(where: { $0.0 == name }) else {
                throw Fail.with("UnknownChild", name)
            }
            return Handle(tree: handle.tree, path: path)
        }
    }

    /// A supervisor's children that have not stopped for good, in order.
    public static func children(_ handle: Handle) -> [(String, Handle)] {
        handle.tree.locked {
            node(handle.tree, handle.path).children.filter { !node(handle.tree, $0.1).removed }.map { ($0.0, Handle(tree: handle.tree, path: $0.1)) }
        }
    }

    /// Restarts a supervisor has made in its current period.
    public static func restartCount(_ handle: Handle) -> Int { handle.tree.locked { node(handle.tree, handle.path).restarts.count } }

    /// The worker now behind a handle (it changes when the worker is
    /// replaced), or nil when the handle has stopped.
    public static func worker(_ handle: Handle) -> Int? {
        handle.tree.locked {
            let n = node(handle.tree, handle.path)
            return n.removed ? nil : n.incarnation
        }
    }

    /// Tell an inbox about a handle's crashes and its stop.
    public static func monitor(_ handle: Handle, _ inbox: Inbox) {
        handle.tree.locked { node(handle.tree, handle.path).observers.insert(inbox, at: 0) }
    }

    /// Link two actors: a crash of either crashes the other.
    public static func link(_ left: Handle, _ right: Handle) {
        left.tree.locked { node(left.tree, left.path).links.insert(right, at: 0) }
        right.tree.locked { node(right.tree, right.path).links.insert(left, at: 0) }
    }

    /// The next event of a handle in an inbox, waiting at most a number of
    /// milliseconds.
    public static func receiveEvent(_ inbox: Inbox, _ handle: Handle, _ milliseconds: Int) -> Event? {
        inbox.receive(handle, milliseconds)
    }
}
