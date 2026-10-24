// A scenario's channels, delegated ends and mailbox send obligations have
// one owner. A single serial queue transfers them atomically and never runs
// application code. Leaving a process releases both its current and its
// unforked work. ref:DEC-sessions-by-construction

import Foundation
import LawSpecRuntime

/// What a receive gives: a payload and the clock it was sent at, or that its
/// sender has gone.
public enum ScenarioReceived {
  case arrived(ScenarioPayload, ScenarioClock)
  case senderGone
}

/// A child process to reserve before it runs: the ends it takes, the mailbox
/// sends it may make and the mailboxes it receives from.
struct ScenarioChild {
  let id: String
  let ends: [ScenarioDestination]
  let sends: [String: Int]
  let receives: [String]
}

/// How the hub's run is carried: over a network (with the program's wire
/// forms, the run's shake, fault options and the deadline in ms) or not.
struct ScenarioIoOptions {
  let network: Bool
  let wire: [Descriptors.Descriptor]?
  let shake: BigInt
  let faults: (MemoryOptions) -> MemoryOptions
  let deadline: Int
}

/// The hub of one scenario run. Every request runs on its serial queue.
final class ScenarioHub: @unchecked Sendable {
  private struct Invalid: Error {
    let reason: String
  }

  private struct Waiting {
    let reply: (ScenarioReceived) -> Void
    let fail: (String) -> Void
    let ticket: Int64
  }

  private final class QueueState {
    var owner = "root"
    var closed = false
    var items: [(ScenarioPayload, ScenarioClock)] = []
    var waiting: Waiting?
    var inFlight = 0
    var remoteGone = false
    var outstanding: Int
    init(_ outstanding: Int) { self.outstanding = outstanding }
  }

  private final class ProcessState {
    var entered: Bool
    let parent: String?
    var sends: [String: Int]
    var closed = false
    init(_ entered: Bool, _ parent: String?, _ sends: [String: Int]) {
      self.entered = entered
      self.parent = parent
      self.sends = sends
    }
  }

  private let queue = DispatchQueue(label: "lawspec.scenario.hub")
  // Destinations in a stable order, so closing follows creation order.
  private var order: [ScenarioDestination] = []
  private var queues: [ScenarioDestination: QueueState] = [:]
  private var processOrder: [String] = []
  private var processes: [String: ProcessState] = [:]
  private var tickets: Int64 = 0
  private var network: ScenarioNetwork?
  private var stopped = false

  init(_ channels: [String], _ mailboxes: [String: Int], _ options: ScenarioIoOptions) throws {
    for name in channels {
      for side in [0, 1] { add(.endOf(name, side), 0) }
    }
    for name in mailboxes.keys.sorted() { add(.mailboxOf(name), mailboxes[name]!) }
    processes["root"] = ProcessState(true, nil, mailboxes)
    processOrder.append("root")
    if options.network {
      // Reports posted while the network starts wait until it is set.
      queue.suspend()
      defer { queue.resume() }
      network = try ScenarioNetwork(
        channels, mailboxes.keys.sorted(), options.wire, options.shake, options.faults,
        options.deadline
      ) { [weak self] incoming in self?.post(incoming) }
    }
  }

  private func add(_ d: ScenarioDestination, _ outstanding: Int) {
    order.append(d)
    queues[d] = QueueState(outstanding)
  }

  private func post(_ incoming: ScenarioIncoming) {
    queue.async { self.handleNetwork(incoming) }
  }

  private static func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw Invalid(reason: reason) }
  }

  private static func describe(_ d: ScenarioDestination) -> String {
    switch d {
    case .endOf(let n, let s): return "end \(n) \(s)"
    case .mailboxOf(let n): return "mailbox " + n
    }
  }

  private func queueOf(_ d: ScenarioDestination) throws -> QueueState {
    guard let q = queues[d] else {
      throw Invalid(reason: "unknown_destination " + Self.describe(d))
    }
    return q
  }

  private func process(_ id: String) throws -> ProcessState {
    guard let p = processes[id] else { throw Invalid(reason: "unknown_process " + id) }
    return p
  }

  @discardableResult
  private func ownedProcess(_ id: String) throws -> ProcessState {
    let p = try process(id)
    try Self.require(!p.closed && p.entered, "not_process_owner " + id)
    return p
  }

  @discardableResult
  private func ownedQueue(_ id: String, _ d: ScenarioDestination) throws -> QueueState {
    let q = try queueOf(d)
    try Self.require(!q.closed && q.owner == id, "not_endpoint_owner " + Self.describe(d))
    return q
  }

  private func discard(_ payload: ScenarioPayload) throws {
    if case .moved(let n, let s) = payload { try closeQueue(.endOf(n, s)) }
  }

  private func arrive(_ d: ScenarioDestination, _ payload: ScenarioPayload, _ clock: ScenarioClock)
    throws
  {
    let q = try queueOf(d)
    if q.closed {
      try discard(payload)
    } else {
      q.items.append((payload, clock))
      try wake(d)
    }
  }

  /// Drain accepted values before reporting that a sender has gone. A moved
  /// end is owned by the queue until its recipient receives it.
  private func wake(_ d: ScenarioDestination) throws {
    let q = try queueOf(d)
    guard let waiting = q.waiting else { return }
    if !q.items.isEmpty {
      let (payload, clock) = q.items.removeFirst()
      q.waiting = nil
      if case .moved(let n, let s) = payload { try queueOf(.endOf(n, s)).owner = q.owner }
      waiting.reply(.arrived(payload, clock))
      return
    }
    let gone: Bool
    switch d {
    case .mailboxOf: gone = q.outstanding + q.inFlight == 0
    case .endOf(let n, let s):
      gone = network == nil ? try queueOf(.endOf(n, 1 - s)).closed : q.remoteGone
    }
    if gone {
      q.waiting = nil
      waiting.reply(.senderGone)
    }
  }

  private func closeQueue(_ d: ScenarioDestination) throws {
    let q = try queueOf(d)
    if q.closed { return }
    // Mark closed before following delegated ends, so cyclic queues end.
    q.closed = true
    if let waiting = q.waiting {
      q.waiting = nil
      waiting.reply(.senderGone)
    }
    let items = q.items
    q.items.removeAll()
    for (payload, _) in items { try discard(payload) }
    if let network {
      network.abandon(d)
    } else if case .endOf(let n, let s) = d {
      try wake(.endOf(n, 1 - s))
    }
  }

  private func closeProcess(_ id: String) throws {
    let p = try process(id)
    if p.closed { return }
    let sends = p.sends
    p.closed = true
    p.sends = [:]
    for child in processOrder where processes[child]?.parent == id { try closeProcess(child) }
    for d in order where queues[d]!.owner == id || id == "root" { try closeQueue(d) }
    for (name, count) in sends.sorted(by: { $0.key < $1.key }) {
      let q = try queueOf(.mailboxOf(name))
      q.outstanding -= count
      try wake(.mailboxOf(name))
    }
  }

  private func reserve(_ parent: String, _ child: ScenarioChild) throws {
    try Self.require(processes[child.id] == nil, "duplicate_process " + child.id)
    let p = try process(parent)
    var remaining = p.sends
    for (name, count) in child.sends.sorted(by: { $0.key < $1.key }) {
      let available = remaining[name] ?? 0
      try Self.require(count >= 0 && count <= available, "send_quota " + name)
      remaining[name] = available - count
    }
    for d in child.ends + child.receives.map({ ScenarioDestination.mailboxOf($0) }) {
      let q = try ownedQueue(parent, d)
      try Self.require(q.waiting == nil, "already_receiving " + Self.describe(d))
      q.owner = child.id
    }
    p.sends = remaining
    processes[child.id] = ProcessState(false, parent, child.sends)
    processOrder.append(child.id)
  }

  private func outcome(_ outcome: ScenarioOutcome) throws {
    func unflight(_ d: ScenarioDestination) throws {
      if case .mailboxOf = d { try queueOf(d).inFlight -= 1 }
    }
    switch outcome {
    case .delivered(let d, let payload, let clock):
      try unflight(d)
      try arrive(d, payload, clock)
    case .lost(let d, let payload):
      try unflight(d)
      try discard(payload)
      try wake(d)
    case .gone(let d):
      try queueOf(d).remoteGone = true
      try wake(d)
    }
  }

  private func handleNetwork(_ incoming: ScenarioIncoming) {
    guard !stopped, let network else { return }
    let outcomes = (try? network.event(incoming)) ?? []
    for o in outcomes { try? outcome(o) }
  }

  private func timedOut(_ d: ScenarioDestination, _ ticket: Int64) {
    guard let q = queues[d], let waiting = q.waiting, waiting.ticket == ticket else { return }
    q.waiting = nil
    waiting.fail("receive_timeout " + Self.describe(d))
  }

  /// Run a request on the queue; its result, or the reason it is invalid.
  private func call<T>(
    _ request: @escaping (@escaping (Result<T, ScenarioFault>) -> Void) throws -> Void
  ) throws -> T {
    let result = Locked<Result<T, ScenarioFault>?>(nil)
    let done = DispatchSemaphore(value: 0)
    let reply: (Result<T, ScenarioFault>) -> Void = { r in
      let first = result.with { (s: inout Result<T, ScenarioFault>?) -> Bool in
        if s != nil { return false }
        s = r
        return true
      }
      if first { done.signal() }
    }
    let work = UncheckedBox((request, reply))
    queue.async {
      let (request, reply) = work.value
      do {
        try request(reply)
      } catch let invalid as Invalid {
        reply(.failure(ScenarioFault(invalid.reason)))
      } catch let e as LawSpecError {
        reply(.failure(ScenarioFault(e.description)))
      } catch {
        reply(.failure(ScenarioFault("\(type(of: error)): \(error)")))
      }
    }
    done.wait()
    switch result.with({ $0 })! {
    case .success(let value): return value
    case .failure(let fault): throw Fail.with("ScenarioIo", fault.reason)
    }
  }

  func fork(_ parent: String, _ children: [ScenarioChild]) throws {
    try call { (reply: @escaping (Result<Void, ScenarioFault>) -> Void) in
      try self.ownedProcess(parent)
      // Reserve every child's obligations before any of them runs.
      for child in children { try self.reserve(parent, child) }
      reply(.success(()))
    }
  }

  func enter(_ id: String) throws {
    try call { (reply: @escaping (Result<Void, ScenarioFault>) -> Void) in
      let p = try self.process(id)
      try Self.require(!p.closed && !p.entered, "cannot_enter " + id)
      p.entered = true
      reply(.success(()))
    }
  }

  func leave(_ id: String) throws {
    try call { (reply: @escaping (Result<Void, ScenarioFault>) -> Void) in
      _ = try self.process(id)
      try self.closeProcess(id)
      reply(.success(()))
    }
  }

  func abandon(_ id: String, _ d: ScenarioDestination) throws {
    try call { (reply: @escaping (Result<Void, ScenarioFault>) -> Void) in
      try self.ownedProcess(id)
      try self.ownedQueue(id, d)
      try self.closeQueue(d)
      reply(.success(()))
    }
  }

  func send(
    _ id: String, _ d: ScenarioDestination, _ payload: ScenarioPayload, _ clock: ScenarioClock
  ) throws {
    try call { (reply: @escaping (Result<Void, ScenarioFault>) -> Void) in
      try self.ownedProcess(id)
      if case .moved(let n, let s) = payload {
        try self.ownedQueue(id, .endOf(n, s))
        try Self.require(
          ScenarioDestination.endOf(n, s) != d, "self_delegation " + Self.describe(d))
      }
      let target: ScenarioDestination
      switch d {
      case .endOf(let n, let s):
        try self.ownedQueue(id, d)
        target = .endOf(n, 1 - s)
      case .mailboxOf(let name):
        let p = try self.process(id)
        let count = p.sends[name] ?? 0
        try Self.require(count > 0, "send_quota " + name)
        p.sends[name] = count - 1
        try self.queueOf(d).outstanding -= 1
        target = d
      }
      if case .moved(let n, let s) = payload { try self.queueOf(.endOf(n, s)).owner = "queued" }
      if try self.queueOf(target).closed {
        try self.discard(payload)
        reply(.success(()))
      } else if let network = self.network {
        if !(try network.send(d, payload, clock, reply)) {
          try self.queueOf(target).inFlight += 1
        } else {
          reply(.success(()))
        }
      } else {
        try self.arrive(target, payload, clock)
        reply(.success(()))
      }
    }
  }

  /// Receive at a destination, within a timeout in ms.
  func receive(_ id: String, _ d: ScenarioDestination, _ timeout: Int) throws -> ScenarioReceived {
    try call { (reply: @escaping (Result<ScenarioReceived, ScenarioFault>) -> Void) in
      try self.ownedProcess(id)
      let q = try self.ownedQueue(id, d)
      try Self.require(q.waiting == nil, "already_receiving " + Self.describe(d))
      try Self.require(timeout >= 0, "invalid_timeout")
      self.tickets += 1
      let ticket = self.tickets
      q.waiting = Waiting(
        reply: { reply(.success($0)) }, fail: { reply(.failure(ScenarioFault($0))) }, ticket: ticket
      )
      self.queue.asyncAfter(
        deadline: .now() + .milliseconds(timeout), execute: { [self] in self.timedOut(d, ticket) })
      try self.wake(d)
    }
  }

  func networkStats() throws -> ScenarioStats? {
    try call { (reply: @escaping (Result<ScenarioStats?, ScenarioFault>) -> Void) in
      reply(.success(self.network?.stats()))
    }
  }

  func stop() throws {
    try call { (reply: @escaping (Result<Void, ScenarioFault>) -> Void) in
      for d in self.order {
        let q = self.queues[d]!
        q.waiting?.fail("hub_stopped")
        q.waiting = nil
      }
      self.network?.close()
      self.stopped = true
      reply(.success(()))
    }
  }
}

enum ScenarioIo {
  /// A hub for a body, stopped after it.
  static func withIo<A>(
    _ channels: [String], _ mailboxes: [String: Int], _ options: ScenarioIoOptions,
    _ body: (ScenarioHub) throws -> A
  ) throws -> A {
    let hub = try ScenarioHub(channels, mailboxes, options)
    defer { try? hub.stop() }
    return try body(hub)
  }
}
