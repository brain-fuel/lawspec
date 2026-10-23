// Concurrent model histories, generated from a valid sequential prefix.
// Every interleaving of the branches must be allowed by the reference.
// The calls run on threads of their own at once; a shared counter records
// each call's interval, and an order consistent with the model (and, for
// linearizability, with real time) must explain the results.
// ref:DEC-stateful-models-linearizability ref:herlihy-wing-linearizability
// ref:wing-gong-linearizability ref:DEC-portable-seeded-generation

import Foundation
import LawSpecRuntime

public enum ModelParallel {
  /// A case: a sequential prefix, then a branch of steps for each thread.
  public typealias Case = (Model.Run, [[(Int, [Value])]])

  /// A call's interval on the shared clock and its outcome.
  public typealias Event = (Int64, Int64, Result<Value, CallFailure>)

  /// A call that failed, as its report shows it.
  public struct CallFailure: Error {
    let text: String
  }

  private static func fail(_ code: String, _ detail: String = "") -> LawSpecError {
    Fail.with(code, detail)
  }

  private static func pending(_ branches: [[(Int, [Value])]], _ positions: [Int]) -> [(
    Int, (Int, [Value])
  )] {
    branches.indices.compactMap { i in
      positions[i] < branches[i].count ? (i, branches[i][positions[i]]) : nil
    }
  }

  private static func advance(_ positions: [Int], _ i: Int) -> [Int] {
    var next = positions
    next[i] += 1
    return next
  }

  /// Whether every interleaving of the branches is allowed by the reference.
  public static func allowed(_ model: Model.Machine, _ c: Case) -> Bool {
    let (prefix, branches) = c
    guard let states = Model.simulate(model, prefix), let last = states.last else { return false }
    return
      (try? Model.withCase(model, prefix.0) { context -> Bool in
        var seen = Set<SearchKey>()
        func allOrders(_ positions: [Int], _ state: Value) -> Bool {
          if !seen.insert(SearchKey(done: positions, state: state)).inserted { return true }
          return pending(branches, positions).allSatisfy { i, step in
            guard let s = try? Model.command(model, step.0),
              let (next, _) = Model.step(s, context, step.1, state)
            else { return false }
            return allOrders(advance(positions, i), next)
          }
        }
        return allOrders(Array(repeating: 0, count: branches.count), last)
      }) ?? false
  }

  private static func generateBranch(
    _ model: Model.Machine, _ context: Model.Context, _ random: Random.Seed, _ size: Int,
    _ count: Int, _ start: Value
  ) throws -> ([(Int, [Value])], Random.Seed) {
    var random = random
    var remaining = count
    var state = start
    var steps = [(Int, [Value])]()
    while remaining != 0 && !model.commands.isEmpty {
      let (index, r1) = Random.below(BigInt(model.commands.count), random)
      let c = try Model.command(model, index.exactly(Int.self)!)
      var r = r1
      let args = try c.arguments.map { d -> Value in
        let (v, next) = try Descriptors.generate(d, model.table, r, size)
        r = next
        return v
      }
      random = r
      remaining -= 1
      if let (next, _) = Model.step(c, context, args, state) {
        state = next
        steps.append((index.exactly(Int.self)!, args))
      }
    }
    return (steps, random)
  }

  private static func trim(_ model: Model.Machine, _ c: Case) -> Case {
    var (prefix, branches) = c
    while !allowed(model, (prefix, branches)) {
      let length = branches.map { $0.count }.max() ?? 0
      guard let i = branches.firstIndex(where: { $0.count == length }), length > 0 else { break }
      branches[i] = Array(branches[i].prefix(length - 1))
    }
    return (prefix, branches)
  }

  /// A case drawn from a random state: a prefix of up to three steps, then a
  /// branch for each thread of one to the branch length steps.
  public static func generateCase(
    _ model: Model.Machine, _ random: Random.Seed, _ size: Int, _ threads: Int, _ branchLength: Int
  ) throws -> (Case, Random.Seed) {
    let (length, r1) = Random.below(4, random)
    let (prefix, r2) = try Model.generateRun(model, r1, length.exactly(Int.self)!, size, false)
    guard let states = Model.simulate(model, prefix), let last = states.last else {
      return ((prefix, Array(repeating: [], count: threads)), r2)
    }
    let (branches, r3) = try Model.withCase(model, prefix.0) {
      context -> ([[(Int, [Value])]], Random.Seed) in
      var r = r2
      var made = [[(Int, [Value])]]()
      for _ in 0..<threads {
        let (n, next) = Random.below(BigInt(branchLength), r)
        let (branch, after) = try generateBranch(
          model, context, next, size, n.exactly(Int.self)! + 1, last)
        r = after
        made.append(branch)
      }
      return (made, r)
    }
    return (trim(model, (prefix, branches)), r3)
  }

  private static func perturb(_ random: Random.Seed) -> Random.Seed {
    let (choice, next) = Random.below(4, random)
    if choice == .one {
      sched_yield()
    } else if !choice.isZero {
      Thread.sleep(forTimeInterval: 0.001)
    }
    return next
  }

  private static func raisedText(_ e: any Error) -> String { "raised \(type(of: e)): \(e)" }

  private static func prefixRun(
    _ model: Model.Machine, _ context: Model.Context, _ steps: [(Int, [Value])], _ system: Any,
    _ start: Value
  ) throws -> Value {
    var expected = start
    try Model.checkState(model, context, system, expected)
    for (i, args) in steps {
      let c = try Model.command(model, i)
      guard let (next, wanted) = Model.step(c, context, args, expected) else {
        throw fail("ModelPrefixInvalid", c.name)
      }
      let (result, _) = try Model.invoke(model, context, c, args, system)
      if !(c.returnsUnit || Scalar.equal(result, wanted)) {
        throw fail(
          "ModelPrefixReturned",
          "\(c.name) returned \(Descriptors.render(result)), expected \(Descriptors.render(wanted))"
        )
      }
      expected = next
      try Model.checkState(model, context, system, expected)
    }
    return expected
  }

  private static func valueOf(_ result: Result<Value, CallFailure>) -> Value {
    if case .success(let v) = result { return v }
    return .unit
  }

  /// Search the orders consistent with each branch's order (and, for
  /// linearizability, real time) for one the reference explains.
  private static func findOrder(
    _ model: Model.Machine, _ context: Model.Context, _ branches: [[(Int, [Value])]],
    _ history: [[Event]],
    _ expected: Value, _ finish: (Value) -> Bool
  ) -> Bool {
    let linear = model.consistency == "linearizable"
    var seen = Set<SearchKey>()
    func visit(_ positions: [Int], _ state: Value) -> Bool {
      if !seen.insert(SearchKey(done: positions, state: state)).inserted { return false }
      let next = pending(branches, positions)
      if next.isEmpty { return finish(state) }
      for (i, step) in next {
        let (called, _, result) = history[i][positions[i]]
        let blocked =
          linear && next.contains { j, _ in j != i && history[j][positions[j]].1 < called }
        if blocked { continue }
        guard let c = try? Model.command(model, step.0),
          let (after, wanted) = Model.step(c, context, step.1, state)
        else { continue }
        let ignore = model.consistency == "eventual" || c.returnsUnit
        if (ignore || Scalar.equal(valueOf(result), wanted)) && visit(advance(positions, i), after)
        {
          return true
        }
      }
      return false
    }
    return visit(Array(repeating: 0, count: branches.count), expected)
  }

  private static func causal(
    _ model: Model.Machine, _ context: Model.Context, _ branches: [[(Int, [Value])]],
    _ history: [[Event]],
    _ expected: Value, _ system: Any
  ) -> Bool {
    zip(branches, history).allSatisfy { branch, events in
      var state = expected
      for ((i, args), (_, _, result)) in zip(branch, events) {
        guard let c = try? Model.command(model, i),
          let (next, wanted) = Model.step(c, context, args, state)
        else { return false }
        if !(c.returnsUnit || Scalar.equal(valueOf(result), wanted)) { return false }
        state = next
      }
      return (try? Model.checkState(Model.withoutAbstraction(model), context, system, state)) != nil
    }
  }

  private static func foldKeys(
    _ model: Model.Machine, _ context: Model.Context,
    _ groups: ArraySlice<[[((Int, [Value]), Event)]]>,
    _ state: Value, _ finish: (Value) -> Bool
  ) -> Bool {
    guard let parts = groups.first else { return finish(state) }
    let branches = parts.map { $0.map { $0.0 } }
    let history = parts.map { $0.map { $0.1 } }
    return findOrder(model, context, branches, history, state) { next in
      foldKeys(model, context, groups.dropFirst(), next, finish)
    }
  }

  private static func byKey(
    _ model: Model.Machine, _ context: Model.Context, _ branches: [[(Int, [Value])]],
    _ history: [[Event]],
    _ expected: Value, _ finish: (Value) -> Bool
  ) -> Bool {
    let n = branches.count
    var groups = [String: [[((Int, [Value]), Event)]]]()
    for (i, (branch, events)) in zip(branches, history).enumerated() {
      for (s, e) in zip(branch, events) {
        guard let c = try? Model.command(model, s.0), let keyIndex = c.key else { return false }
        let key = Descriptors.render(s.1[keyIndex])
        var parts = groups[key] ?? Array(repeating: [], count: n)
        parts[i].append((s, e))
        groups[key] = parts
      }
    }
    let ordered = groups.keys.sorted { Scalar.compareText($0, $1) < 0 }.map { groups[$0]! }
    return foldKeys(model, context, ordered[...], expected, finish)
  }

  /// Whether a parallel history has an order consistent with the model.
  public static func consistent(
    _ model: Model.Machine, _ context: Model.Context, _ branches: [[(Int, [Value])]],
    _ history: [[Event]],
    _ expected: Value, _ final: Value?, _ system: Any
  ) -> Bool {
    func finish(_ state: Value) -> Bool {
      if let actual = final, !Scalar.equal(actual, state) { return false }
      return (try? Model.checkState(Model.withoutAbstraction(model), context, system, state)) != nil
    }
    if model.consistency == "causal" {
      return causal(model, context, branches, history, expected, system)
    }
    let canPartition =
      model.consistency == "linearizable" && model.perKey
      && branches.joined().allSatisfy { (try? Model.command(model, $0.0))?.key != nil }
    if canPartition { return byKey(model, context, branches, history, expected, finish) }
    return findOrder(model, context, branches, history, expected, finish)
  }

  private static func letter(_ i: Int) -> String { String(UnicodeScalar(UInt8(65 + i))) }

  /// Run a case once, its branches at the same time, with scheduling
  /// perturbed from a shake value; nil when an order explains the results.
  public static func execute(_ model: Model.Machine, _ c: Case, _ shake: UInt64) -> String? {
    let ((startArgs, steps), branches) = c
    do {
      return try Model.withSystem(model, startArgs, steps.count) {
        context, system, start -> String? in
        let finalPrefix = try prefixRun(model, context, steps, system, start)
        let clock = Locked<Int64>(0)
        let tick: @Sendable () -> Int64 = {
          clock.with {
            $0 += 1
            return $0
          }
        }
        let results = Locked([[Event]](repeating: [], count: branches.count))
        let group = DispatchGroup()
        let shared = UncheckedBox((model, context, system))
        for (i, branch) in branches.enumerated() {
          group.enter()
          let work = UncheckedBox(branch)
          LawThread.start {
            let (model, context, system) = shared.value
            var random = Random.seed(
              BigInt(shake) ^ (BigInt(i + 1) * BigInt(UInt64(0x9e37_79b9_7f4a_7c15))))
            var events = [Event]()
            for (index, args) in work.value {
              random = perturb(random)
              let called = tick()
              let result: Result<Value, CallFailure>
              do {
                let s = try Model.command(model, index)
                do {
                  result = .success(try Model.invoke(model, context, s, args, system).0)
                } catch {
                  result = .failure(CallFailure(text: s.name + ": " + raisedText(error)))
                }
              } catch {
                result = .failure(CallFailure(text: raisedText(error)))
              }
              let returned = tick()
              random = perturb(random)
              events.append((called, returned, result))
            }
            results.with { $0[i] = events }
            group.leave()
          }
        }
        group.wait()
        let history = results.with { $0 }
        for events in history {
          for (_, _, r) in events { if case .failure(let e) = r { return e.text } }
        }
        let final = try model.abstractRun.map {
          try Model.callback($0, context, [try Model.systemState(model, system)])
        }
        if consistent(model, context, branches, history, finalPrefix, final, system) { return nil }
        let shown = history.enumerated().map { i, events in
          letter(i) + ": "
            + events.map { a, b, r -> String in
              let text: String
              switch r {
              case .success(let v): text = Descriptors.render(v)
              case .failure(let e): text = e.text
              }
              return "[\(a),\(b)] \(text)"
            }.joined(separator: ", ")
        }
        return "no consistent order: " + shown.joined(separator: "; ")
      }
    } catch {
      return raisedText(error)
    }
  }

  /// Shrink candidates: remove a prefix step, remove a branch step, then
  /// shrink a branch step's arguments.
  public static func candidates(_ model: Model.Machine, _ c: Case) throws -> [Case] {
    let (prefix, branches) = c
    let (startArgs, steps) = prefix
    var result = [Case]()
    for i in steps.indices {
      var copy = steps
      copy.remove(at: i)
      result.append(((startArgs, copy), branches))
    }
    for (i, branch) in branches.enumerated() {
      for k in branch.indices {
        var b = branch
        b.remove(at: k)
        var copy = branches
        copy[i] = b
        result.append((prefix, copy))
      }
    }
    for (i, branch) in branches.enumerated() {
      for (k, (index, values)) in branch.enumerated() {
        let ds = try Model.command(model, index).arguments
        for (a, (d, v)) in zip(ds, values).enumerated() {
          for value in try Descriptors.shrink(d, v, model.table) {
            var vs = values
            vs[a] = value
            var b = branch
            b[k] = (index, vs)
            var copy = branches
            copy[i] = b
            result.append((prefix, copy))
          }
        }
      }
    }
    return result
  }

  private static func repeats(_ model: Model.Machine, _ c: Case, _ count: Int, _ shake: UInt64)
    -> String?
  {
    var shake = shake
    for _ in 0..<count {
      if let error = execute(model, c, shake) { return error }
      shake &+= 1
    }
    return nil
  }

  /// The smallest case still failing within a budget of attempts.
  public static func shrinkCase(
    _ model: Model.Machine, _ c: Case, _ failure: String, _ count: Int, _ budget: Int,
    _ shake: UInt64
  ) throws -> (Case, String) {
    var budget = budget
    for candidate in try candidates(model, c) {
      if budget == 0 { break }
      let found = allowed(model, candidate) ? repeats(model, candidate, count, shake) : nil
      if let reason = found {
        return try shrinkCase(model, candidate, reason, count, budget - 1, shake)
      }
      budget -= 1
    }
    return (c, failure)
  }

  /// A case as text: its prefix, then each branch, at the same time.
  public static func describeCase(_ model: Model.Machine, _ c: Case) -> String {
    let (prefix, branches) = c
    let parts = branches.enumerated().map { i, b -> String in
      let shown =
        b.isEmpty ? "nothing" : String(Model.describe(model, ([], b)).dropFirst("start(); ".count))
      return letter(i) + ": " + shown
    }
    let joined: String
    switch parts.count {
    case 0: joined = "nothing"
    case 1: joined = parts[0]
    default: joined = parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }
    return Model.describe(model, prefix) + ", then " + joined + " at the same time"
  }

  /// How many cases, how many runs of each, the shrink budget, the threads
  /// and the longest branch.
  public struct Options {
    public var cases = 50
    public var repeats = 10
    public var maxShrinks = 300
    public var threads = 3
    public var branchLength = 5
    public var seed: BigInt? = nil
    public init() {}
  }

  /// Check a shared model's concurrent histories, with options.
  public static func checkWith(_ options: Options, _ model: Model.Machine) throws {
    if !model.shared { throw fail("ModelNotShared", model.name) }
    if options.cases <= 0 || options.repeats <= 0 || options.threads <= 0
      || options.branchLength <= 0 || options.maxShrinks < 0
    {
      throw fail("ModelInvalidOptions", model.name)
    }
    let start = Model.seed(options.seed)
    var random = Random.Seed(state: start.state ^ 0x5bd1_e995)
    for n in 0..<options.cases {
      let (c, r1) = try generateCase(
        model, random, 1 + n % 8, options.threads, options.branchLength)
      let (shake, r2) = Random.next(r1)
      if let failure = repeats(model, c, options.repeats, shake) {
        let (smaller, found) = try shrinkCase(
          model, c, failure, Swift.max(2, options.repeats / 2), options.maxShrinks, shake)
        throw Fail.with(
          "ModelInconsistent",
          "model \(model.name) is not \(model.consistency): seed \(start.state) (LAWSPEC_SEED=\(start.state) replays it), case \(n), shake \(shake): \(describeCase(model, smaller)); \(found)"
        )
      }
      random = r2
    }
  }

  /// Check a shared model's concurrent histories.
  public static func check(_ model: Model.Machine) throws { try checkWith(Options(), model) }
}
