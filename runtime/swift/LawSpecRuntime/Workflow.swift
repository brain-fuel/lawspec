// Workflows in Swift: stages run under their policies (gates, retries with
// jittered backoff, timeouts, hedges, caches) and a workflow compensates
// the stages that succeeded when it fails. A workflow runtime owns the
// policy state, the virtual time and the trace; it is ambient (Ambient), so
// a test's calls and their concurrent work share it. Without one, workflows
// share the default runtime on the real clock, and a Clock in scope supplies
// its view of time. ref:DEC-domain-modeling-primitives
// ref:DEC-async-native-tasks ref:DEC-portable-seeded-generation

import Foundation

public enum Workflow {
  /// Something that happened in a stage: start, finish, sleep, wait, hedge,
  /// cached or compensate, with the attempt (or delay) number.
  public struct Event: Sendable {
    public let kind: String
    public let stage: String
    public let number: Int64
    public let succeeded: Bool
  }

  /// Where a runtime's time comes from.
  public enum Clock {
    case real
    case virtual
    case callbacks(now: () throws -> Int64, sleep: (Int64) throws -> Void, isVirtual: Bool)
  }

  private final class StageRecord {
    let key: String
    var passed: [(GateKey, Policy.Gate)] = []
    var time: Int64
    init(key: String, time: Int64) {
      self.key = key
      self.time = time
    }
  }

  struct GateKey: Hashable {
    let stage: String
    let kind: Policy.GateKind
  }

  /// A runtime's policy state: virtual time, the jitter stream, the trace,
  /// gate states, the cache, compensation frames and running stages. Every
  /// change is under its lock; gate callbacks are pure checked definitions.
  public final class State: @unchecked Sendable {
    private let gate = NSRecursiveLock()
    private var now: Int64
    private var random: Random.Seed
    private var trace: [Event] = []
    private var states: [GateKey: Value] = [:]
    private var cache: [String: [(Value, Value, Int64)]] = [:]
    private var frames: [Int64: [(String, () throws -> Value)]] = [:]
    private var stages: [Int64: StageRecord] = [:]
    private var counter: Int64 = 0

    init(seed: BigInt, time: Int64) {
      now = time
      random = Random.seed(seed)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
      gate.lock()
      defer { gate.unlock() }
      return try body()
    }

    public var time: Int64 { locked { now } }
    func setTime(_ t: Int64) { locked { now = t } }
    func sleep(_ delay: Int64) { locked { now += Swift.max(0, delay) } }

    func jitter(_ kind: Policy.Jitter, _ delay: Int64, _ previous: Int64, _ baseDelay: Int64)
      -> Int64
    {
      locked {
        let (value, next) = Policy.jitter(kind, delay, previous, baseDelay, random)
        random = next
        return value
      }
    }

    func event(_ e: Event) { locked { trace.append(e) } }
    public var events: [Event] { locked { trace } }

    func cached(_ key: String, _ input: Value, _ at: Int64) -> Value? {
      locked {
        let live = (cache[key] ?? []).filter { at < $0.2 }
        cache[key] = live
        return live.first { Scalar.equal($0.0, input) }?.1
      }
    }

    func store(_ key: String, _ input: Value, _ value: Value, _ at: Int64, _ ttl: Int64) {
      locked {
        let live = (cache[key] ?? []).filter { at < $0.2 && !Scalar.equal($0.0, input) }
        cache[key] = [(input, value, at + ttl)] + live
      }
    }

    func newFrame() -> Int64 {
      locked {
        counter += 1
        frames[counter] = []
        return counter
      }
    }

    func undo(_ frame: Int64, _ stage: String, _ undo: @escaping () throws -> Value) {
      locked {
        if let undos = frames[frame] { frames[frame] = [(stage, undo)] + undos }
      }
    }

    func takeFrame(_ frame: Int64) -> [(String, () throws -> Value)] {
      locked {
        let undos = frames[frame] ?? []
        frames[frame] = nil
        return undos
      }
    }

    func newStage(_ key: String, _ at: Int64) -> Int64 {
      locked {
        counter += 1
        stages[counter] = StageRecord(key: key, time: at)
        return counter
      }
    }

    /// A gate's decision for a running stage, updating the gate's state.
    func decide(_ stage: Int64, _ g: Policy.Gate, _ at: Int64) throws -> Value {
      try locked {
        guard let record = stages[stage] else { throw Fail.with("UnknownStage") }
        let key = GateKey(stage: record.key, kind: g.kind)
        let before = try states[key] ?? g.start(.int(BigInt(at)))
        let step = try g.admit(before, .int(BigInt(at)))
        guard case .data(_, let pair) = step, pair.count == 2 else {
          throw Fail.with("InvalidGateStep", "\(step)")
        }
        states[key] = pair[0]
        if case .data("lawspec.resilience::type::Gate::Admit", let f) = pair[1], f.isEmpty {
          record.passed.append((key, g))
        }
        record.time = at
        return pair[1]
      }
    }

    /// A stage ended: each gate it passed records the outcome.
    func finishStage(_ stage: Int64, _ at: Int64, _ succeeded: Bool) throws {
      try locked {
        guard let record = stages[stage] else { return }
        stages[stage] = nil
        for (key, g) in record.passed {
          if let finish = g.finish, let state = states[key] {
            states[key] = try finish(state, .int(BigInt(at)), .bool(succeeded))
          }
        }
      }
    }
  }

  /// A workflow runtime: its state, its clock, whether gates and caches
  /// apply, and whether it was installed explicitly (an explicit runtime's
  /// clock is not replaced by a Clock in scope).
  public struct Runtime {
    public let state: State
    public let clock: Clock
    public let gates: Bool
    public let explicit: Bool
  }

  private static let ambientKey = "lawspec.workflow.runtime"
  nonisolated(unsafe) private static let shared = Runtime(
    state: State(seed: .zero, time: 0), clock: .real, gates: true, explicit: false)

  private static func scoped<T>(_ runtime: Runtime, _ body: (Runtime) throws -> T) rethrows -> T {
    try Ambient.with(ambientKey, runtime) { try body(runtime) }
  }

  private static func seedOf() -> BigInt {
    BigInt(ProcessInfo.processInfo.environment["LAWSPEC_SEED"] ?? "") ?? .zero
  }

  /// Run a body with its own runtime on a clock, from a seed.
  public static func withClock<T>(_ clock: Clock, _ seed: BigInt, _ body: (Runtime) throws -> T)
    rethrows -> T
  {
    try scoped(
      Runtime(state: State(seed: seed, time: 0), clock: clock, gates: true, explicit: true), body)
  }

  /// A runtime on a virtual clock that starts at 0 and moves only when told.
  public static func withVirtual<T>(_ seed: BigInt, _ body: (Runtime) throws -> T) rethrows -> T {
    try withClock(.virtual, seed, body)
  }

  /// A runtime on the real clock.
  public static func withReal<T>(_ seed: BigInt, _ body: (Runtime) throws -> T) rethrows -> T {
    try withClock(.real, seed, body)
  }

  /// A law's runtime: virtual time and no gates or caches, from the run's
  /// seed; a Clock in scope (`using virtual clock`) supplies the time.
  public static func withTestRuntime<T>(_ body: () throws -> T) throws -> T {
    try scoped(
      Runtime(state: State(seed: seedOf(), time: 0), clock: .virtual, gates: false, explicit: false)
    ) { _ in try body() }
  }

  private static func isRealClock(_ handler: Effects.Handler) -> Bool {
    switch handler {
    case .recording(_, let inner): return isRealClock(inner)
    case .stateless(let clauses): return clauses[Defaults.realClockMarker] != nil
    case .stateful: return false
    }
  }

  /// The ambient runtime (the shared default outside any).
  public static func ambient() -> Runtime { (Ambient.get(ambientKey) as? Runtime) ?? shared }

  /// The runtime a stage runs under: the ambient one (or the shared default),
  /// timed by the Clock in scope unless the runtime was installed explicitly.
  public static func current(_ schema: Schema) -> Runtime {
    let base = ambient()
    guard !base.explicit, let handler = schema.handlers["lawspec.time::ability::Clock"] else {
      return base
    }
    let now = { () throws -> Int64 in
      let instant = try Effects.invoke(handler, schema, "now", [])
      guard case .data(_, let f) = instant, f.count == 1, case .int(let t) = f[0],
        let micros = t.exactly(Int64.self)
      else {
        throw Fail.with("InvalidInstant", "\(instant)")
      }
      return micros
    }
    let sleep = { (delay: Int64) throws -> Void in
      _ = try Effects.invoke(
        handler, schema, "sleep",
        [.data("lawspec.time::type::Duration::Duration", [.int(BigInt(delay))])])
    }
    return Runtime(
      state: base.state,
      clock: .callbacks(now: now, sleep: sleep, isVirtual: !isRealClock(handler)),
      gates: base.gates, explicit: base.explicit)
  }

  private static func isVirtual(_ runtime: Runtime) -> Bool {
    switch runtime.clock {
    case .virtual: return true
    case .real: return false
    case .callbacks(_, _, let v): return v
    }
  }

  /// The runtime's time, in microseconds.
  public static func now(_ runtime: Runtime) throws -> Int64 {
    switch runtime.clock {
    case .real: return Defaults.nowMicros()
    case .virtual: return runtime.state.time
    case .callbacks(let read, _, _): return try read()
    }
  }

  /// Let time pass: at once on a virtual clock.
  public static func sleep(_ runtime: Runtime, _ delay: Int64) throws {
    guard delay > 0 else { return }
    switch runtime.clock {
    case .real: Defaults.sleepMicros(delay)
    case .virtual: runtime.state.sleep(delay)
    case .callbacks(_, let wait, _): try wait(delay)
    }
  }

  /// Set a virtual runtime's time.
  public static func setTime(_ runtime: Runtime, _ time: Int64) throws {
    guard case .virtual = runtime.clock else {
      throw Fail.with("NotVirtual", "only a virtual runtime's time is set")
    }
    runtime.state.setTime(time)
  }

  /// What happened, in order.
  public static func trace(_ runtime: Runtime) -> [Event] { runtime.state.events }

  private static func event(
    _ runtime: Runtime, _ policy: Policy.StagePolicy, _ kind: String, _ number: Int64,
    _ succeeded: Bool
  ) {
    runtime.state.event(
      Event(kind: kind, stage: policy.stage, number: number, succeeded: succeeded))
  }

  // MARK: Real-clock timeouts and hedges. ref:DEC-async-native-tasks

  private static func micros() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1000) }

  /// The attempts running at once, and the first that ended.
  private final class Attempts: @unchecked Sendable {
    let condition = NSCondition()
    var finished: [(Int, Int64, Result<Value, any Error>)] = []
  }

  /// Run attempts of a body on the real clock: a hedge starts another after
  /// the delay, up to most; the first success wins, or the last failure after
  /// every attempt; past the deadline the stage is TimedOut. Losing attempts
  /// are cancelled through their scope, never awaited.
  public static func runAttempts(
    _ timeout: Int64?, _ hedge: (Int64, Int64)?, _ body: @escaping () throws -> Value,
    _ onHedge: (Int64) -> Void
  ) throws -> Value {
    try Tasks.withScope { _ in
      let start = micros()
      let deadline: Int64? = timeout.flatMap { $0 > 0 ? start + $0 : nil }
      let (delay, most): (Int64, Int64) =
        hedge.map { (Swift.max(0, $0.0), Swift.max(1, $0.1)) } ?? (0, 1)
      let attempts = Attempts()
      let work = UncheckedBox(body)
      var running: Set<Int> = []
      func launch(_ number: Int64) {
        if number > 1 { onHedge(number) }
        let id = Int(number)
        running.insert(id)
        LawThread.start {
          let result = Result { try work.value() }
          attempts.condition.lock()
          attempts.finished.append((id, micros(), result))
          attempts.condition.signal()
          attempts.condition.unlock()
        }
      }
      launch(1)
      var started: Int64 = 1
      var next = start + delay
      while true {
        let hedgeAt: Int64? = started < most ? next : nil
        let timer: Int64? = [deadline, hedgeAt].compactMap { $0 }.min()
        attempts.condition.lock()
        if attempts.finished.isEmpty {
          if let t = timer {
            let wait = Swift.max(0, t - micros())
            _ = attempts.condition.wait(until: Date(timeIntervalSinceNow: Double(wait) / 1e6))
          } else {
            attempts.condition.wait()
          }
        }
        let done = attempts.finished.isEmpty ? nil : attempts.finished.removeFirst()
        attempts.condition.unlock()
        if let (id, ended, result) = done {
          running.remove(id)
          if let d = deadline, ended > d { return Policy.stageFailure("TimedOut") }
          let value = try result.get()
          if !Policy.failed(value) { return value }
          if running.isEmpty && started >= most { return value }
          if running.isEmpty {
            if deadline == nil || micros() < deadline! {
              started += 1
              launch(started)
              next = micros() + delay
            } else {
              return Policy.stageFailure("TimedOut")
            }
          }
        } else {
          let at = micros()
          if let d = deadline, at >= d { return Policy.stageFailure("TimedOut") }
          if started < most && at >= next {
            started += 1
            launch(started)
            next = micros() + delay
          }
        }
      }
    }
  }

  // MARK: Stages and workflows

  private struct Frame {
    let state: State
    let id: Int64
  }

  private static let frameKey = "lawspec.workflow.frame"

  private static func virtualHedge(
    _ hedge: (Int64, Int64)?, _ body: () throws -> Value, _ onHedge: (Int64) -> Void,
    _ started: Int64
  ) throws -> Value {
    guard let (_, most) = hedge else { return try body() }
    var count = started
    while true {
      let result = try body()
      if Policy.failed(result) && count < most {
        count += 1
        onHedge(count)
      } else {
        return result
      }
    }
  }

  private static func timed(
    _ runtime: Runtime, _ policy: Policy.StagePolicy, _ body: @escaping () throws -> Value
  ) throws -> Value {
    let onHedge = { (n: Int64) in event(runtime, policy, "hedge", n, true) }
    if isVirtual(runtime) {
      let began = try now(runtime)
      let result = try virtualHedge(policy.hedge, body, onHedge, 1)
      if let t = policy.timeout, t > 0, try now(runtime) - began > t {
        return Policy.stageFailure("TimedOut")
      }
      return result
    }
    if runtime.gates && (policy.timeout != nil || policy.hedge != nil) {
      return try runAttempts(policy.timeout, policy.hedge, body, onHedge)
    }
    return try body()
  }

  private static func retryError(_ wraps: Bool, _ error: Value) -> Value? {
    if !wraps { return error }
    switch error {
    case .data("lawspec.resilience::type::StageFailure::StepFailed", let f) where f.count == 1:
      return f[0]
    case .data("lawspec.resilience::type::StageFailure::TimedOut", let f) where f.isEmpty:
      return error
    default: return nil
    }
  }

  private static func retryWait(
    _ runtime: Runtime, _ retry: Policy.Retry, _ number: Int64, _ reason: Value, _ previous: Int64
  ) throws -> Int64? {
    if case .custom(let decide) = retry.strategy {
      return try Policy.retryDecision(
        try decide(
          .int(BigInt(number)), reason,
          .data("lawspec.time::type::Duration::Duration", [.int(BigInt(previous))])))
    }
    let delay = try Policy.retryDelay(retry.strategy, number)
    let baseDelay = try Policy.retryDelay(retry.strategy, 2)
    return runtime.state.jitter(retry.jitter, delay, previous, baseDelay)
  }

  private static func attempts(
    _ runtime: Runtime, _ policy: Policy.StagePolicy, _ body: @escaping () throws -> Value
  ) throws -> Value {
    var number: Int64 = 1
    var previous: Int64 = 0
    while true {
      event(runtime, policy, "start", number, false)
      let result = try timed(runtime, policy, body)
      let isFailure = Policy.failed(result)
      event(runtime, policy, "finish", number, !isFailure)
      guard isFailure, let retry = policy.retry, case .data(_, let fields) = result,
        fields.count == 1,
        let reason = retryError(policy.wraps, fields[0])
      else { return result }
      let exhausted = retry.attempts > 0 && number >= retry.attempts
      var refused = false
      if let condition = retry.condition {
        guard case .bool(let holds) = try condition(reason) else { throw Fail.with("BoolRequired") }
        refused = !holds
      }
      if exhausted || refused { return result }
      guard let delay = try retryWait(runtime, retry, number + 1, reason, previous) else {
        return result
      }
      event(runtime, policy, "sleep", delay, true)
      try sleep(runtime, delay)
      number += 1
      previous = delay
    }
  }

  private static func gateFailure(_ kind: Policy.GateKind) -> String {
    switch kind {
    case .breaker: return "CircuitOpen"
    case .limit: return "RateLimited"
    case .bulkhead: return "Saturated"
    }
  }

  private static func passGate(
    _ runtime: Runtime, _ stage: Int64, _ policy: Policy.StagePolicy, _ g: Policy.Gate
  ) throws -> String? {
    var waited: Int64 = 0
    while true {
      let decision = try runtime.state.decide(stage, g, try now(runtime))
      switch decision {
      case .data("lawspec.resilience::type::Gate::Admit", let f) where f.isEmpty: return nil
      case .data("lawspec.resilience::type::Gate::Reject", let f) where f.isEmpty:
        return gateFailure(g.kind)
      case _ where g.wait == .noWait: return gateFailure(g.kind)
      case .data("lawspec.resilience::type::Gate::WaitFor", let f) where f.count == 1:
        guard case .int(let d) = f[0], let delay = d.exactly(Int64.self) else {
          throw Fail.with("InvalidGateDecision", "\(decision)")
        }
        if case .within(let most) = g.wait, waited + delay > most { return gateFailure(g.kind) }
        event(runtime, policy, "wait", delay, true)
        try sleep(runtime, delay)
        waited += delay
      default:
        throw Fail.with("InvalidGateDecision", "\(decision)")
      }
    }
  }

  private static func rememberUndo(
    _ runtime: Runtime, _ policy: Policy.StagePolicy, _ result: Value
  ) {
    guard let f = Ambient.get(frameKey) as? Frame, f.state === runtime.state,
      let undo = policy.compensate
    else { return }
    var value = result
    if case .data("Either::Right", let fields) = result, fields.count == 1 { value = fields[0] }
    let kept = value
    runtime.state.undo(f.id, policy.stage) { try undo(kept) }
  }

  /// Run a stage of a workflow under its policy. The input is the stage's
  /// argument, the key of its cache.
  public static func runStage(
    _ schema: Schema, _ policy: Policy.StagePolicy, _ body: @escaping () throws -> Value,
    _ input: Value
  ) throws -> Value {
    let runtime = current(schema)
    let caching = runtime.gates && policy.cache != nil
    if caching, let value = runtime.state.cached(policy.key, input, try now(runtime)) {
      event(runtime, policy, "cached", 0, true)
      return value
    }
    let stage = runtime.state.newStage(policy.key, try now(runtime))
    let gates = runtime.gates ? policy.gates : []
    let outcome = Result { () throws -> Value in
      for g in gates {
        if let kind = try passGate(runtime, stage, policy, g) { return Policy.stageFailure(kind) }
      }
      return try attempts(runtime, policy, body)
    }
    let succeeded: Bool
    if case .success(let v) = outcome { succeeded = !Policy.failed(v) } else { succeeded = false }
    try runtime.state.finishStage(stage, try now(runtime), succeeded)
    let value = try outcome.get()
    if succeeded {
      rememberUndo(runtime, policy, value)
      if caching, let ttl = policy.cache {
        runtime.state.store(policy.key, input, value, try now(runtime), ttl)
      }
    }
    return value
  }

  /// Run a workflow: when it fails, undo the stages that succeeded, the
  /// latest first.
  public static func runWorkflow(_ schema: Schema, _ body: () throws -> Value) throws -> Value {
    let runtime = current(schema)
    let id = runtime.state.newFrame()
    let outcome = Result {
      try Ambient.with(frameKey, Frame(state: runtime.state, id: id)) { try body() }
    }
    let undos = runtime.state.takeFrame(id)
    let result = try outcome.get()
    if Policy.failed(result) {
      for (stageName, undo) in undos {
        runtime.state.event(Event(kind: "compensate", stage: stageName, number: 0, succeeded: true))
        _ = try undo()
      }
    }
    return result
  }
}
