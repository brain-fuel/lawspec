// Scenario histories carry vector clocks through sends, receives and
// fork/join. Consistency depends on these message edges as well as each
// caller's own order; real time is required only for linearizability.
// ref:DEC-sessions-by-construction ref:DEC-stateful-models-linearizability
// ref:wing-gong-linearizability

import LawSpecRuntime

/// A search position: which events are done (as bits or positions) and the
/// model state there, compared structurally.
struct SearchKey: Hashable {
  let done: [Int]
  let state: Value
  static func == (a: SearchKey, b: SearchKey) -> Bool {
    a.done == b.done && Recorded.identical(a.state, b.state)
  }
  func hash(into hasher: inout Hasher) {
    hasher.combine(done)
    state.portableHash(into: &hasher)
  }
}

public enum History {
  /// A completed call: the model command it ran, its arguments and result, its
  /// interval on the shared clock, its process and its vector clocks.
  public struct Event {
    public let command: Int
    public let arguments: [Value]
    public let result: Value
    public let called: Int64
    public let returned: Int64
    public let process: String
    public let callClock: [String: Int64]
    public let returnClock: [String: Int64]
    public init(
      command: Int, arguments: [Value], result: Value, called: Int64, returned: Int64,
      process: String,
      callClock: [String: Int64], returnClock: [String: Int64]
    ) {
      self.command = command
      self.arguments = arguments
      self.result = result
      self.called = called
      self.returned = returned
      self.process = process
      self.callClock = callClock
      self.returnClock = returnClock
    }
  }

  /// Whether a's return happened before b's call, by their vector clocks.
  public static func happenedBefore(_ a: Event, _ b: Event) -> Bool {
    a.returnClock.allSatisfy { proc, count in (b.callClock[proc] ?? 0) >= count }
  }

  private static func before(_ mode: String, _ a: Event, _ b: Event) -> Bool {
    mode == "linearizable" ? a.returned < b.called : happenedBefore(a, b)
  }

  private static func mask<S: Sequence>(_ indices: S) -> Set<Int> where S.Element == Int {
    Set(indices)
  }

  private static func search(
    _ model: Model.Machine, _ context: Model.Context, _ history: [Event], _ preds: [Set<Int>],
    _ members: [Int], _ checked: Set<Int>, _ expected: Value, _ judge: (Value) -> Bool
  ) -> Bool {
    let full = mask(members)
    var seen = Set<SearchKey>()
    func visit(_ done: Set<Int>, _ state: Value) -> Bool {
      if done == full { return judge(state) }
      if !seen.insert(SearchKey(done: done.sorted(), state: state)).inserted { return false }
      for i in members {
        let dependencies = preds[i].intersection(full)
        let available = !done.contains(i) && dependencies.isSubset(of: done)
        if !available { continue }
        let e = history[i]
        guard let c = try? Model.command(model, e.command) else { continue }
        guard let (next, wanted) = Model.step(c, context, e.arguments, state) else { continue }
        let ignore = !checked.contains(i) || c.returnsUnit
        if (ignore || Scalar.equal(e.result, wanted)) && visit(done.union([i]), next) {
          return true
        }
      }
      return false
    }
    return visit([], expected)
  }

  /// Whether a history has an order consistent with the model: real time for
  /// linearizability, message order otherwise; causal histories are checked
  /// in each process's view. Final is the system's abstract final state, if any.
  public static func consistent(
    _ model: Model.Machine, _ context: Model.Context, _ events: [Event], _ expected: Value,
    _ final: Value?, _ system: Any
  ) -> Bool {
    let history = events
    let indices = Array(history.indices)
    let mode = model.consistency
    let preds = indices.map { i in
      mask(indices.filter { j in j != i && before(mode, history[j], history[i]) })
    }
    func judge(_ compareFinal: Bool, _ state: Value) -> Bool {
      if compareFinal, let actual = final, !Scalar.equal(actual, state) { return false }
      return (try? Model.checkState(Model.withoutAbstraction(model), context, system, state)) != nil
    }
    if mode == "causal" {
      let processes = Array(Set(events.map { $0.process })).sorted {
        Scalar.compareText($0, $1) < 0
      }
      if processes.isEmpty { return judge(false, expected) }
      return processes.allSatisfy { proc in
        let own = indices.filter { history[$0].process == proc }
        var visible = own
        for j in indices {
          for i in own where j != i && happenedBefore(history[j], history[i]) { visible.append(j) }
        }
        let members = Array(Set(visible)).sorted()
        return search(model, context, history, preds, members, mask(own), expected) {
          judge(false, $0)
        }
      }
    }
    let checked: Set<Int> = mode == "eventual" ? [] : mask(indices)
    return search(model, context, history, preds, indices, checked, expected) { judge(true, $0) }
  }
}
