// Portable stateful model runs over checked logical callbacks. A fresh
// context owns each generation, replay and shrink attempt, so no handler
// state or workflow state is shared between attempts. The draws, the
// rejected reference steps, the crash injection of actor models and the
// shrink order are those of every other runtime, so one seed replays one
// run on every target. ref:DEC-stateful-models-linearizability
// ref:DEC-portable-seeded-generation ref:DEC-shrink-within-domain

import Foundation
import LawSpecRuntime

/// What an actor model needs from the actor runtime: a supervised actor
/// holding the system's state, restarted after a crash.
public protocol ModelActorHost {
  /// Start one permanent child under a one-for-one supervisor that allows
  /// the given number of restarts, run the body with the child, then stop.
  /// start makes the first state; restart makes a state from the state at
  /// the crash.
  func withActor<R>(
    _ restarts: Int, _ start: @escaping () throws -> Value,
    _ restart: @escaping (Value) throws -> Value,
    _ body: (AnyObject) throws -> R
  ) throws -> R
  /// Run an update on the actor's state in the actor: its reply and next state.
  func call(_ actor: AnyObject, _ update: @escaping (Value) throws -> (Value, Value)) throws
    -> Value
  /// Crash the actor, waiting until its supervisor has restarted it.
  func crash(_ actor: AnyObject) throws
  /// The actor's current state.
  func state(_ actor: AnyObject) throws -> Value
}

public enum Model {
  /// What a callback runs with: the schema, with the model's production
  /// handlers in scope, and the case's symbols.
  public typealias CallbackContext = (Schema, SymbolContext)

  /// A checked entry of the program: the case's context and its arguments.
  public typealias Callback = (CallbackContext, [Value]) throws -> Value

  /// Runs a body in a fresh case context: generated code makes a symbol
  /// context, takes the program's schema and installs production handlers
  /// around the body.
  public typealias ContextFactory = ((CallbackContext) throws -> Any) throws -> Any

  public enum StepKind {
    case command
    case crash
  }

  /// A command of the model (or the injected crash of an actor model).
  public struct Step {
    public let name: String
    public let arguments: [Descriptors.Descriptor]
    public let statePosition: Int
    public let returnsUnit: Bool
    public let needs: [(String, BigInt)]
    public let shifts: [(String, BigInt)]
    public let key: Int?
    public let restart: Bool
    public let kind: StepKind
    public let run: Callback
    public let reference: Callback
    public let when: Callback?
  }

  public struct Machine {
    public let name: String
    public let shared: Bool
    public let actor: Bool
    public let table: Descriptors.Table
    public let startArguments: [Descriptors.Descriptor]
    public let startIndices: [BigInt]
    public let startRun: Callback
    public let startModel: Callback
    public let commands: [Step]
    public let steps: [Step]
    public let restartStep: Step?
    public var abstractRun: Callback?
    public let invariants: [(String, Callback)]
    public let perKey: Bool
    public let consistency: String
    public var context: ContextFactory
    public var actors: (any ModelActorHost)?
  }

  /// A case of the run: the model's context, its start arguments and the model.
  public struct Context {
    public let value: CallbackContext
    public let start: [Value]
    public let model: Machine
  }

  /// A run: start arguments, and each step's index and arguments.
  public typealias Run = ([Value], [(Int, [Value])])

  /// Why a run failed, and at which step (0 before the first).
  public struct Failure {
    public let step: Int
    public let reason: String
  }

  static func fail(_ code: String, _ detail: String = "") -> LawSpecError {
    Fail.with(code, detail)
  }

  private static func require(_ condition: Bool, _ code: String) throws {
    if !condition { throw fail(code) }
  }

  private static var noCallback: Callback { { _, _ in throw fail("ModelMissingCallback") } }

  private static func atom(_ d: Descriptors.Descriptor) throws -> String {
    switch d {
    case .atom(let a): return a
    case .quoted(let q): return q
    case .number(let n): return n.description
    default: throw fail("InvalidModelSpec", "\(d)")
    }
  }

  private static func fields(_ forms: [Descriptors.Descriptor]) -> [String: [Descriptors
    .Descriptor]]
  {
    var table = [String: [Descriptors.Descriptor]]()
    for f in forms {
      if case .forms(let parts) = f, case .atom(let k)? = parts.first {
        table[k] = Array(parts.dropFirst())
      }
    }
    return table
  }

  private static func one(_ key: String, _ f: [String: [Descriptors.Descriptor]]) throws
    -> Descriptors.Descriptor
  {
    guard let vs = f[key], vs.count == 1 else { throw fail("InvalidModelSpec", key) }
    return vs[0]
  }

  private static func flag(_ key: String, _ forms: [Descriptors.Descriptor]) -> Bool {
    forms.contains(.forms([.atom(key), .atom("true")]))
  }

  private static func form(_ key: String, _ forms: [Descriptors.Descriptor]) throws -> [Descriptors
    .Descriptor]
  {
    for f in forms {
      if case .forms(let parts) = f, case .atom(let k)? = parts.first, k == key {
        return Array(parts.dropFirst())
      }
    }
    throw fail("InvalidModelSpec", key)
  }

  private static func pairs(_ ds: [Descriptors.Descriptor]) throws -> [(String, BigInt)] {
    try ds.map { d in
      guard case .forms(let parts) = d, parts.count == 2, case .atom(let k) = parts[0],
        case .number(let n) = parts[1]
      else {
        throw fail("InvalidModelSpec", "\(d)")
      }
      return (k, n)
    }
  }

  private static func readCommand(
    _ forms: [Descriptors.Descriptor], _ callbacks: (Callback, Callback, Callback?)
  ) throws -> Step {
    guard forms.count >= 2, case .atom("command") = forms[0] else {
      throw fail("InvalidModelSpec", "command")
    }
    let f = fields(Array(forms.dropFirst(2)))
    guard case .number(let position) = try one("state", f) else {
      throw fail("InvalidModelSpec", "state")
    }
    var key: Int? = nil
    if case .number(let k) = try one("key", f) { key = k.exactly(Int.self) }
    return Step(
      name: try atom(forms[1]), arguments: f["arguments"] ?? [],
      statePosition: position.exactly(Int.self) ?? 0,
      returnsUnit: try atom(one("unit", f)) == "true", needs: try pairs(f["needs"] ?? []),
      shifts: try pairs(f["shifts"] ?? []),
      key: key, restart: try atom(one("restart", f)) == "true", kind: .command,
      run: callbacks.0, reference: callbacks.1, when: callbacks.2)
  }

  private static var defaultContext: ContextFactory {
    { body in try body((try Schema.create([], [], 64), SymbolContext())) }
  }

  /// A model from its spec text (LawSpec.MachineSpec), its start entries (the
  /// system's and the reference's), each command's run, reference and optional
  /// precondition, its optional abstraction and its invariants.
  public static func create(
    _ spec: String, _ start: (Callback, Callback), _ callbacks: [(Callback, Callback, Callback?)],
    _ abstractRun: Callback?, _ invariants: [Callback]
  ) throws -> Machine {
    let forms = try Descriptors.read(spec)
    guard case .forms(let head)? = forms.first, head.count == 3, case .atom("machine") = head[0]
    else {
      throw fail("InvalidModelSpec", "machine")
    }
    let name = try atom(head[1])
    let sharing = try atom(head[2])
    let startFields = fields(try form("start", forms))
    let commandForms = forms.compactMap { f -> [Descriptors.Descriptor]? in
      if case .forms(let parts) = f, case .atom("command")? = parts.first { return parts }
      return nil
    }
    let kinds = try form("invariants", forms).map(atom)
    try require(commandForms.count == callbacks.count, "ModelCommandCallbacks")
    try require(kinds.count == invariants.count, "ModelInvariantCallbacks")
    let all = try zip(commandForms, callbacks).map { try readCommand($0.0, $0.1) }
    let restarts = all.filter { $0.restart }
    try require(restarts.count <= 1, "ModelRestartCallbacks")
    let commands = all.filter { !$0.restart }
    let actor = flag("actor", forms)
    guard let consistencyForm = try form("consistency", forms).first else {
      throw fail("InvalidModelSpec", "consistency")
    }
    let consistency = try atom(consistencyForm)
    try require(sharing == "linear" || sharing == "shared", "ModelInvalidSharing")
    try require(
      ["linearizable", "sequential", "causal", "eventual"].contains(consistency),
      "ModelInvalidConsistency")
    try require(consistency != "eventual" || abstractRun != nil, "ModelEventualRequiresAbstraction")
    try require(!actor || sharing == "shared", "ModelActorMustBeShared")
    try require(actor || restarts.isEmpty, "ModelRestartRequiresActor")
    let crash = Step(
      name: "crash", arguments: [], statePosition: 0, returnsUnit: true, needs: [], shifts: [],
      key: nil,
      restart: false, kind: .crash, run: noCallback, reference: noCallback, when: nil)
    var table = Descriptors.Table()
    for f in forms {
      if case .forms(let parts) = f, parts.count >= 2, case .atom("data") = parts[0] {
        table[try atom(parts[1])] = f
      }
    }
    let indices = try (startFields["indices"] ?? []).map { d -> BigInt in
      guard case .number(let n) = d else { throw fail("InvalidModelSpec", "\(d)") }
      return n
    }
    return Machine(
      name: name, shared: sharing == "shared", actor: actor, table: table,
      startArguments: startFields["arguments"] ?? [], startIndices: indices,
      startRun: start.0, startModel: start.1, commands: commands,
      steps: commands + (actor ? [crash] : []),
      restartStep: restarts.first, abstractRun: abstractRun,
      invariants: Array(zip(kinds, invariants)),
      perKey: flag("perkey", forms), consistency: consistency, context: defaultContext, actors: nil)
  }

  /// The model with the context factory generated code supplies.
  public static func withContext(_ factory: @escaping ContextFactory, _ model: Machine) -> Machine {
    var made = model
    made.context = factory
    return made
  }

  /// The model with the actor runtime an actor model runs its system on.
  public static func withActors(_ host: any ModelActorHost, _ model: Machine) -> Machine {
    var made = model
    made.actors = host
    return made
  }

  /// A context factory whose handler factories are made with each body's fresh
  /// symbols, as generated code builds them.
  public static func contextWith(
    _ schema: Schema,
    _ factories: @escaping (SymbolContext) throws -> [(String, (Schema) throws -> Effects.Handler)]
  ) -> ContextFactory {
    { body in
      let symbols = SymbolContext()
      let made = try factories(symbols)
      if made.isEmpty { return try body((schema, symbols)) }
      return try Effects.withScope(schema, made) { scoped in try body((scoped, symbols)) }
    }
  }

  /// The step at an index (commands, then the injected crash).
  public static func command(_ model: Machine, _ index: Int) throws -> Step {
    if index < 0 || index >= model.steps.count { throw fail("ModelInvalidStep", String(index)) }
    return model.steps[index]
  }

  /// Whether a command's index preconditions admit the current indices.
  public static func admits(_ step: Step, _ indices: [BigInt]) -> Bool {
    zip(step.needs, indices).allSatisfy { need, i in need.0 == "atleast" ? i >= need.1 : i == need.1
    }
  }

  /// The indices after a command.
  public static func shifted(_ step: Step, _ indices: [BigInt]) -> [BigInt] {
    if step.shifts.isEmpty { return indices }
    return zip(step.shifts, indices).map { shift, i in shift.0 == "by" ? i + shift.1 : shift.1 }
  }

  /// Run a body in a fresh case context.
  public static func withCase<A>(
    _ model: Machine, _ startArgs: [Value], _ body: (Context) throws -> A
  ) throws -> A {
    let result = try model.context { value in
      try body(Context(value: value, start: startArgs, model: model))
    }
    return result as! A
  }

  public static func callback(_ f: Callback, _ context: Context, _ arguments: [Value]) throws
    -> Value
  {
    try f(context.value, arguments)
  }

  public static func initial(_ model: Machine, _ context: Context) throws -> Value {
    try callback(model.startModel, context, context.start)
  }

  /// The reference's step: the next model state and the reply, or nil when
  /// the reference rejects it. An invalid reference removes a candidate; it
  /// never turns the implementation's failure into a pass.
  public static func step(_ s: Step, _ context: Context, _ args: [Value], _ state: Value) -> (
    Value, Value
  )? {
    do {
      switch s.kind {
      case .crash:
        let next: Value
        if let r = context.model.restartStep {
          next = try callback(r.reference, context, [state])
        } else {
          next = try initial(context.model, context)
        }
        return (next, .unit)
      case .command:
        if let w = s.when, !Scalar.equal(try callback(w, context, [state]), .bool(true)) {
          return nil
        }
        let out = try callback(s.reference, context, args + [state])
        if s.returnsUnit { return (out, .unit) }
        if case .data(_, let pair) = out, pair.count == 2 { return (pair[1], pair[0]) }
        return nil
      }
    } catch {
      return nil
    }
  }

  /// The model states a run passes through, or nil when the reference
  /// rejects it.
  public static func simulate(_ model: Machine, _ run: Run) -> [Value]? {
    let (startArgs, steps) = run
    return
      (try? withCase(model, startArgs) { context -> [Value]? in
        var indices = model.startIndices
        var state = try initial(model, context)
        var states = [state]
        for (i, args) in steps {
          let c = try command(model, i)
          if !admits(c, indices) { return nil }
          guard let (next, _) = step(c, context, args, state) else { return nil }
          indices = shifted(c, indices)
          state = next
          states.append(state)
        }
        return states
      }) ?? nil
  }

  private static func arguments(
    _ model: Machine, _ ds: [Descriptors.Descriptor], _ random: Random.Seed, _ size: Int
  ) throws -> ([Value], Random.Seed) {
    var r = random
    let values = try ds.map { d -> Value in
      let (v, next) = try Descriptors.generate(d, model.table, r, size)
      r = next
      return v
    }
    return (values, r)
  }

  /// A run drawn from a random state, of at most a length, at a size; crashes
  /// are injected (one step in eight) only when asked, and only for actors.
  public static func generateRun(
    _ model: Machine, _ random: Random.Seed, _ length: Int, _ size: Int, _ crashes: Bool
  ) throws -> (Run, Random.Seed) {
    let (startArgs, r1) = try arguments(model, model.startArguments, random, size)
    return try withCase(model, startArgs) { context -> (Run, Random.Seed) in
      guard let started = try? initial(model, context) else { return ((startArgs, []), r1) }
      var random = r1
      var remaining = length
      var indices = model.startIndices
      var state = started
      var steps = [(Int, [Value])]()
      while remaining != 0 {
        let allowed = model.commands.indices.filter { admits(model.commands[$0], indices) }
        if allowed.isEmpty { break }
        let (choice, next1) = Random.below(BigInt(allowed.count), random)
        var index = allowed[choice.exactly(Int.self)!]
        var next2 = next1
        if crashes && model.actor {
          let (crash, r) = Random.below(8, next1)
          if crash.isZero { index = model.commands.count }
          next2 = r
        }
        let c = try command(model, index)
        let (args, next3) = try arguments(model, c.arguments, next2, size)
        random = next3
        remaining -= 1
        if let (after, _) = step(c, context, args, state) {
          indices = shifted(c, indices)
          state = after
          steps.append((index, args))
        }
      }
      return ((startArgs, steps), random)
    }
  }

  static func hostOf(_ model: Machine) throws -> any ModelActorHost {
    guard let host = model.actors else { throw fail("ModelActorRuntimeMissing", model.name) }
    return host
  }

  /// Run a body with the system started (an actor model's under a
  /// supervisor), its context and the reference's initial state.
  public static func withSystem<A>(
    _ model: Machine, _ startArgs: [Value], _ restarts: Int,
    _ body: (Context, Any, Value) throws -> A
  ) throws -> A {
    try withCase(model, startArgs) { context in
      let start = { () throws -> Value in try callback(model.startRun, context, startArgs) }
      if !model.actor { return try body(context, try start(), try initial(model, context)) }
      let restart = { (state: Value) throws -> Value in
        if let r = model.restartStep { return try callback(r.run, context, [state]) }
        return try start()
      }
      return try hostOf(model).withActor(restarts, start, restart) { actor in
        try body(context, actor, try initial(model, context))
      }
    }
  }

  private static func insertState(_ s: Step, _ args: [Value], _ state: Value) -> [Value] {
    let position = Swift.min(s.statePosition, args.count)
    return Array(args[..<position]) + [state] + Array(args[position...])
  }

  private static func pair(_ out: Value) throws -> (Value, Value) {
    guard case .data(_, let p) = out, p.count == 2 else {
      throw fail("ModelInvalidReply", Recorded.debug(out))
    }
    return (p[0], p[1])
  }

  /// Run a step on the system: its reply and the system after it.
  public static func invoke(
    _ model: Machine, _ context: Context, _ s: Step, _ args: [Value], _ system: Any
  ) throws -> (Value, Any) {
    switch s.kind {
    case .crash:
      try hostOf(model).crash(system as AnyObject)
      return (.unit, system)
    case .command where model.actor:
      let reply = try hostOf(model).call(system as AnyObject) { state in
        let out = try callback(s.run, context, insertState(s, args, state))
        return s.returnsUnit ? (.unit, out) : try pair(out)
      }
      return (reply, system)
    case .command:
      let state = system as! Value
      let out = try callback(s.run, context, insertState(s, args, state))
      if model.shared { return (out, system) }
      if s.returnsUnit {
        guard case .data(_, let f) = out, f.count == 1 else {
          throw fail("ModelInvalidReply", Recorded.debug(out))
        }
        return (.unit, f[0])
      }
      let (reply, next) = try pair(out)
      return (reply, next)
    }
  }

  struct ModelFailure: Error, CustomStringConvertible {
    let reason: String
    var description: String { reason }
  }

  /// The system's state, as its abstraction and state invariants see it.
  public static func systemState(_ model: Machine, _ system: Any) throws -> Value {
    if model.actor { return try hostOf(model).state(system as AnyObject) }
    return system as! Value
  }

  /// Check the system against the reference state: its abstraction, then the
  /// invariants on the model state and on the system state.
  public static func checkState(
    _ model: Machine, _ context: Context, _ system: Any, _ expected: Value
  ) throws {
    let state = try systemState(model, system)
    if let a = model.abstractRun {
      let actual = try callback(a, context, [state])
      if !Scalar.equal(actual, expected) {
        throw ModelFailure(
          reason: "state \(Descriptors.render(actual)), expected \(Descriptors.render(expected))")
      }
    }
    for (kind, invariant) in model.invariants {
      let value = kind == "model" ? expected : state
      switch try callback(invariant, context, [value]) {
      case .bool(true): continue
      case .bool(false): throw ModelFailure(reason: "invariant on the " + kind + " failed")
      case let other:
        throw ModelFailure(reason: "invariant on the \(kind) gave \(Descriptors.render(other))")
      }
    }
  }

  /// A model without its abstraction (for the checks of each order).
  public static func withoutAbstraction(_ model: Machine) -> Machine {
    var made = model
    made.abstractRun = nil
    return made
  }

  static func raised(_ e: any Error) -> String {
    if let failure = e as? ModelFailure { return failure.reason }
    return "raised \(type(of: e)): \(e)"
  }

  /// Run a run on the system, checking each reply and state.
  public static func execute(_ model: Machine, _ run: Run) -> Failure? {
    let (startArgs, steps) = run
    do {
      return try withSystem(model, startArgs, steps.count) { context, system, start -> Failure? in
        var indices = model.startIndices
        var expected = start
        var system = system
        var n = 0
        for (i, args) in steps {
          do {
            try checkState(model, context, system, expected)
          } catch {
            return Failure(step: n, reason: raised(error))
          }
          let c: Step
          do { c = try command(model, i) } catch { return Failure(step: n, reason: raised(error)) }
          if !admits(c, indices) { return Failure(step: n + 1, reason: "invalid step") }
          guard let (next, wanted) = step(c, context, args, expected) else {
            return Failure(step: n + 1, reason: "invalid step")
          }
          let result: Value
          do {
            (result, system) = try invoke(model, context, c, args, system)
          } catch {
            return Failure(step: n + 1, reason: raised(error))
          }
          if !(c.returnsUnit || Scalar.equal(result, wanted)) {
            return Failure(
              step: n + 1,
              reason:
                "returned \(Descriptors.render(result)), expected \(Descriptors.render(wanted))")
          }
          indices = shifted(c, indices)
          expected = next
          n += 1
        }
        do {
          try checkState(model, context, system, expected)
        } catch {
          return Failure(step: n, reason: raised(error))
        }
        return nil
      }
    } catch {
      return Failure(step: 0, reason: raised(error))
    }
  }

  private static func halves(_ n: Int) -> [Int] {
    var result = [Int]()
    var k = n
    while k != 0 {
      result.append(k)
      k /= 2
    }
    return result
  }

  private static func removeRange<T>(_ values: [T], _ start: Int, _ size: Int) -> [T] {
    let before = values[..<start]
    let rest = values[start...]
    return Array(before) + Array(rest.dropFirst(Swift.min(size, rest.count)))
  }

  static func smallerArgs(_ model: Machine, _ ds: [Descriptors.Descriptor], _ args: [Value]) throws
    -> [[Value]]
  {
    var result = [[Value]]()
    for (i, (d, arg)) in zip(ds, args).enumerated() {
      for v in try Descriptors.shrink(d, arg, model.table) {
        var copy = args
        copy[i] = v
        result.append(copy)
      }
    }
    return result
  }

  /// Shrink candidates in the portable order: remove chunks of steps, then
  /// shrink each step's arguments, then the start arguments.
  public static func candidates(_ model: Machine, _ run: Run) throws -> [Run] {
    let (startArgs, steps) = run
    let n = steps.count
    var result = [Run]()
    for size in halves(n / 2) {
      for start in stride(from: 0, to: n, by: size) {
        result.append((startArgs, removeRange(steps, start, size)))
      }
    }
    for (k, (i, values)) in steps.enumerated() {
      for smaller in try smallerArgs(model, try command(model, i).arguments, values) {
        var copy = steps
        copy[k] = (i, smaller)
        result.append((startArgs, copy))
      }
    }
    for smaller in try smallerArgs(model, model.startArguments, startArgs) {
      result.append((smaller, steps))
    }
    return result
  }

  /// The smallest failing run within a budget of attempts.
  public static func shrinkRun(_ model: Machine, _ run: Run, _ failure: Failure, _ budget: Int)
    throws -> (Run, Failure)
  {
    var budget = budget
    for candidate in try candidates(model, run) {
      if budget == 0 { break }
      let result: Failure? = simulate(model, candidate) == nil ? nil : execute(model, candidate)
      if let found = result { return try shrinkRun(model, candidate, found, budget - 1) }
      budget -= 1
    }
    return (run, failure)
  }

  private static func describeStep(_ name: String, _ args: [Value]) -> String {
    name + "(" + args.map(Descriptors.render).joined(separator: ", ") + ")"
  }

  /// A run as text: start(...); command(...); ...
  public static func describe(_ model: Machine, _ run: Run) -> String {
    let (startArgs, steps) = run
    return
      ([describeStep("start", startArgs)]
      + steps.map { describeStep((try? command(model, $0.0).name) ?? "?", $0.1) }).joined(
        separator: "; ")
  }

  /// The run's seed: given, LAWSPEC_SEED, or 0.
  public static func seed(_ given: BigInt?) -> Random.Seed {
    if let n = given { return Random.seed(n) }
    if let text = ProcessInfo.processInfo.environment["LAWSPEC_SEED"], !text.isEmpty,
      let n = BigInt(text)
    {
      return Random.seed(n)
    }
    return Random.seed(.zero)
  }

  /// How many cases, how long a run may be, how many shrink attempts, and
  /// the seed (otherwise LAWSPEC_SEED, or 0).
  public struct Options {
    public var cases = 100
    public var maxLength = 20
    public var maxShrinks = 2000
    public var seed: BigInt? = nil
    public init() {}
  }

  /// Check a model's sequential runs, with options.
  public static func checkWith(_ options: Options, _ model: Machine) throws {
    try require(options.cases > 0, "ModelRequiresCases")
    try require(options.maxLength >= 0, "ModelInvalidLength")
    try require(options.maxShrinks >= 0, "ModelInvalidShrinks")
    let start = seed(options.seed)
    var random = start
    for n in 0..<options.cases {
      let (length, r1) = Random.below(BigInt(options.maxLength + 1), random)
      let (run, r2) = try generateRun(model, r1, length.exactly(Int.self)!, 1 + n % 8, true)
      if let failure = execute(model, run) {
        let (smaller, found) = try shrinkRun(model, run, failure, options.maxShrinks)
        throw Fail.with(
          "ModelFailed",
          "model \(model.name): seed \(start.state) (LAWSPEC_SEED=\(start.state) replays it), case \(n): \(describe(model, smaller)); at step \(found.step): \(found.reason)"
        )
      }
      random = r2
    }
  }

  /// Check a model's sequential runs.
  public static func check(_ model: Machine) throws { try checkWith(Options(), model) }
}
