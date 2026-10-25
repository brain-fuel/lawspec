// Services the generated definitions and laws share: contracts, equations,
// helpers, recordings and concurrent groups. Values stay portable until a
// native boundary. ref:DEC-typed-core-boundary

import Foundation

public enum Runtime {
  /// A portable boolean as a Swift one.
  public static func truth(_ value: Value) throws -> Bool {
    guard case .bool(let b) = value else { throw Fail.with("BoolRequired", "\(value)") }
    return b
  }

  public static func not(_ value: Value) throws -> Value { .bool(!(try truth(value))) }

  /// The item of a list of values at a position.
  public static func item(_ index: Int, _ values: [Value]) -> Value { values[index] }

  /// A data value's field at a position (a list's head and tail).
  public static func field(_ value: Value, _ index: Int) throws -> Value {
    switch (value, index) {
    case (.data(_, let fields), _) where index < fields.count: return fields[index]
    case (.list(let items), 0) where !items.isEmpty: return items[0]
    case (.list(let items), 1) where !items.isEmpty: return .list(Array(items.dropFirst()))
    default: throw Fail.with("ExpectedData", "\(value)")
    }
  }

  /// Whether a value was built by a constructor.
  public static func hasTag(_ tag: String, _ value: Value) -> Bool {
    switch value {
    case .data(let t, _): return t == tag
    case .list(let items): return tag == (items.isEmpty ? "List::Nil" : "List::Cons")
    default: return false
    }
  }

  /// A match no branch covers.
  public static func noMatch(_ value: Value) throws -> Value {
    throw Fail.with("MatchFailure", "\(value)")
  }

  /// Whether every element of a list satisfies a predicate.
  public static func allElements(_ value: Value, _ predicate: (Value) throws -> Value) throws
    -> Value
  {
    guard case .list(let items) = value else { throw Fail.with("ListRequired") }
    for item in items where !(try truth(predicate(item))) { return .bool(false) }
    return .bool(true)
  }

  /// Three-valued finite search, visiting every needed item exactly once.
  public static func searchElements(
    _ universal: Bool, _ value: Value, _ predicate: (Value) throws -> Value
  ) throws -> Value {
    guard case .list(let items) = value else { throw Fail.with("ListRequired") }
    let decisive = BigInt(universal ? -1 : 1)
    var result = -decisive
    for item in items {
      guard case .int(let code) = try predicate(item) else {
        throw Fail.with("InvalidFiniteSearchOutcome")
      }
      if code == decisive { return .int(code) }
      if code == 0 {
        result = 0
      } else if code != -decisive {
        throw Fail.with("InvalidFiniteSearchOutcome")
      }
    }
    return .int(result)
  }

  /// Whether every payload of a container satisfies its parameter's predicate.
  public static func allPayloads(
    _ value: Value, _ t: TypeRef, _ predicates: [(Value) throws -> Value], _ schema: Schema
  ) throws -> Value {
    .bool(try Schema.allPayloads(value, t, predicates.map { p in { try truth(p($0)) } }, schema))
  }

  /// Nullable or Optional, absent.
  public static func absent(_ kind: String) -> Value { .presence(kind: kind, value: nil) }

  /// Nullable or Optional, present.
  public static func present(_ kind: String, _ value: Value) -> Value {
    .presence(kind: kind, value: value)
  }

  /// Fail a contract unless it holds.
  public static func require(_ holds: Value, _ context: String) throws {
    switch holds {
    case .bool(true): return
    case .bool(false): throw Fail.with("ContractFailed", context)
    default: throw Fail.with("NonBooleanContract", context)
    }
  }

  /// Where two unequal values first differ: the path to the item or field,
  /// and both values there.
  private static func difference(_ actual: Value, _ expected: Value) -> String {
    func walk(_ a: Value, _ b: Value, _ path: [String]) -> ([String], String, String)? {
      switch (a, b) {
      case (.list(let xs), .list(let ys)):
        if let i = Array(zip(xs, ys)).firstIndex(where: {
          Recorded.renderPlain($0) != Recorded.renderPlain($1)
        }) {
          return walk(xs[i], ys[i], path + ["item \(i + 1)"])
        }
        if xs.count == ys.count { return nil }
        return (path + ["length"], String(xs.count), String(ys.count))
      case (.data(let tx, let fx), .data(let ty, let fy)) where tx == ty && fx.count == fy.count:
        let name = Recorded.lastPart(tx)
        guard
          let i = Array(zip(fx, fy)).firstIndex(where: {
            Recorded.renderPlain($0) != Recorded.renderPlain($1)
          })
        else { return nil }
        return walk(fx[i], fy[i], path + ["field \(i + 1) of \(name)"])
      default:
        if path.isEmpty { return nil }
        return (path, Recorded.renderPlain(a), Recorded.renderPlain(b))
      }
    }
    guard let (path, shownActual, shownExpected) = walk(actual, expected, []) else { return "" }
    return
      " | first difference at \(path.joined(separator: ", ")): expected \(shownExpected), actual \(shownActual)"
  }

  /// An equation of a law: both sides are kept for the report.
  public static func assertEqual(_ actual: Value, _ expected: Value, _ label: String) throws
    -> Value
  {
    if Scalar.equal(actual, expected) { return .bool(true) }
    throw Fail.with(
      "EquationFailed",
      "\(label): actual \(Recorded.renderPlain(actual)), expected \(Recorded.renderPlain(expected))\(difference(actual, expected))"
    )
  }

  /// Name the definition or law a LawSpec failure happened in.
  public static func contextual<T>(_ identity: String, _ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let failure as LawSpecError {
      throw failure.within(identity)
    }
  }

  private static func recordedRoot() -> String {
    if let given = ProcessInfo.processInfo.environment["LAWSPEC_RECORDED"], !given.isEmpty {
      return given
    }
    let manager = FileManager.default
    let start = manager.currentDirectoryPath
    var folder = URL(fileURLWithPath: start)
    while true {
      if manager.fileExists(atPath: folder.appendingPathComponent("lawspec.json").path)
        || manager.fileExists(atPath: folder.appendingPathComponent("recorded").path)
      {
        return folder.appendingPathComponent("recorded").path
      }
      let parent = folder.deletingLastPathComponent()
      if parent.path == folder.path {
        return URL(fileURLWithPath: start).appendingPathComponent("recorded").path
      }
      folder = parent
    }
  }

  /// Compare a value's text with its recording, or record it under
  /// LAWSPEC_UPDATE_RECORDED=1 (lawspec test --update-recorded).
  public static func recordedText(_ key: String, _ text: String) throws -> Value {
    var url = URL(fileURLWithPath: recordedRoot())
    for part in key.split(separator: "/") { url.appendPathComponent(String(part)) }
    let manager = FileManager.default
    if ProcessInfo.processInfo.environment["LAWSPEC_UPDATE_RECORDED"] == "1" {
      try? manager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      do { try (text + "\n").write(to: url, atomically: true, encoding: .utf8) } catch {
        throw Fail.with("RecordingFailed", "recorded/\(key): \(error)")
      }
      return .bool(true)
    }
    if manager.fileExists(atPath: url.path) {
      var stored = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      if stored.hasSuffix("\n") { stored.removeLast() }
      if String.portableEqual(stored, text) { return .bool(true) }
      throw Fail.with(
        "RecordingDiffers",
        "recorded/\(key) differs: expected \(stored), actual \(text) (lawspec test --update-recorded records the new value)"
      )
    }
    throw Fail.with(
      "RecordingMissing",
      "no recording recorded/\(key); run lawspec test --update-recorded to record \(text)")
  }

  /// A recorded value, at its type.
  public static func recorded(_ key: Value, _ value: Value, _ t: TypeRef, _ schema: Schema) throws
    -> Value
  {
    guard case .text(let k) = key else { throw Fail.with("TextRequired", "recorded") }
    return try recordedText(k, Recorded.text(value, t, schema))
  }

  /// A built-in helper by name.
  public static func helper(_ name: String, _ values: [Value], _ types: [String], _ bits: Int)
    throws -> Value
  {
    switch (name, values.count) {
    case ("incompleteSearch", 1):
      if case .text(let reason) = values[0] {
        throw Fail.with("QuantifierSearchIncomplete", reason)
      }
      throw Fail.with("QuantifierSearchIncomplete")
    case ("unreachable", _): throw Fail.with("Unreachable")
    case ("regexMatches", 2):
      if case .text(let pattern) = values[0], case .text(let text) = values[1] {
        return .bool(try Regex.matches(pattern, text))
      }
    case ("recorded", 2):
      if case .text(let key) = values[0], types.count < 2 {
        return try recordedText(key, Recorded.renderPlain(values[1]))
      }
      return try recorded(
        values[0], values[1], Scalar.typeOf(types[1]), Schema.create([], [], bits))
    default:
      break
    }
    return try Scalar.helper(name, values, types, bits)
  }

  /// Run steps concurrently, each on its own thread, and return their values
  /// in source order. Every step finishes before the first failure in source
  /// order is raised.
  public static func concurrently(_ steps: [() throws -> Value]) throws -> [Value] {
    let results = Locked([Result<Value, any Error>?](repeating: nil, count: steps.count))
    let group = DispatchGroup()
    for (i, step) in steps.enumerated() {
      group.enter()
      let work = UncheckedBox(step)
      LawThread.start {
        let outcome = Result { try work.value() }
        results.with { $0[i] = outcome }
        group.leave()
      }
    }
    group.wait()
    return try results.with { $0 }.map { try $0!.get() }
  }

  /// Wait, on this thread, for an async adapter's result.
  public static func await<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let result = Locked<Result<T, any Error>?>(nil)
    let done = DispatchSemaphore(value: 0)
    Task.detached {
      let outcome: Result<T, any Error>
      do { outcome = .success(try await body()) } catch { outcome = .failure(error) }
      result.with { $0 = outcome }
      done.signal()
    }
    done.wait()
    return try result.with { $0 }!.get()
  }

  /// Discard a value computed for its checks.
  public static func ignore(_ value: Value) {}

  /// An integer value from its digits.
  public static func integer(_ digits: String) throws -> Value { try Scalar.integerLiteral(digits) }
}

/// A value moved to another thread by code that knows it is used there alone.
public struct UncheckedBox<T>: @unchecked Sendable {
  public let value: T
  public init(_ value: T) { self.value = value }
}

/// Threads with a large stack for the synchronous runtime: laws, concurrent
/// steps and timed tests run on them, never on Swift's cooperative pool, so
/// waiting for an async adapter never starves the pool.
public enum LawThread {
  /// The stack each thread gets: deep recursion over values needs more than
  /// a secondary thread's default.
  public static let stackSize = 64 << 20

  /// Start a body on a new thread.
  public static func start(_ body: @escaping @Sendable () -> Void) {
    // The new thread sees this one's ambient context (Ambient).
    let context = UncheckedBox(Ambient.capture())
    let thread = Thread {
      Ambient.restore(context.value)
      body()
    }
    thread.stackSize = stackSize
    thread.start()
  }

  /// Run a synchronous body on a new thread and wait for it, without
  /// blocking the caller's thread: what a generated test calls.
  public static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T
  {
    try await withCheckedThrowingContinuation { continuation in
      start {
        do { continuation.resume(returning: try body()) } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Run a synchronous body on a new thread and wait for it, blocking.
  public static func runBlocking<T>(_ body: @escaping () throws -> T) throws -> T {
    let result = Locked<Result<T, any Error>?>(nil)
    let done = DispatchSemaphore(value: 0)
    let work = UncheckedBox(body)
    start {
      let outcome = Result { try work.value() }
      result.with { $0 = outcome }
      done.signal()
    }
    done.wait()
    return try result.with { $0 }!.get()
  }
}

extension Runtime {
  /// Wait, on this thread, for an async adapter called by a boxed closure
  /// (its captures need not be Sendable: only this call uses them).
  public static func awaitBoxed<T>(_ body: UncheckedBox<() async throws -> T>) throws -> T {
    try Runtime.await { try await body.value() }
  }
}

/// How the embedding API runs the runtime for native callers: a LawSpec
/// failure inside is a broken contract, a programmer error, so it traps, as
/// Swift's own checked arithmetic does; a definition's declared failure is
/// its typed throw.
public enum Embedding {
  private static func trap(_ error: any Error) -> Never {
    fatalError("LawSpec: \(error)")
  }

  /// Run a definition with no failure.
  public static func run<T>(_ body: @escaping () throws -> T) -> T {
    do {
      return try LawThread.runBlocking(body)
    } catch {
      trap(error)
    }
  }

  /// Run typed code on this thread: it calls no async adapter, so it needs
  /// no runtime thread of its own.
  public static func inline<T>(_ body: () throws -> T) -> T {
    do {
      return try body()
    } catch {
      trap(error)
    }
  }

  /// Run typed code that fails with E on this thread.
  public static func inlineFailing<T, E: Error>(
    _ ability: String, _ convert: (Value) throws -> E, _ body: () throws -> T
  ) throws(E) -> T {
    do {
      return try body()
    } catch let raised as RaisedFailure where raised.ability == ability {
      do {
        throw try convert(raised.failure)
      } catch let failure as E {
        throw failure
      } catch {
        trap(error)
      }
    } catch {
      trap(error)
    }
  }

  /// Run a definition that fails with E: its failure is thrown as E.
  public static func runFailing<T, E: Error>(
    _ ability: String, _ convert: @escaping (Value) throws -> E, _ body: @escaping () throws -> T
  ) throws(E) -> T {
    let outcome: Result<T, any Error> = Result { try LawThread.runBlocking(body) }
    switch outcome {
    case .success(let value):
      return value
    case .failure(let raised as RaisedFailure) where raised.ability == ability:
      do {
        throw try convert(raised.failure)
      } catch let failure as E {
        throw failure
      } catch {
        trap(error)
      }
    case .failure(let error):
      trap(error)
    }
  }

  /// Run an async definition with no failure, on a runtime thread.
  public static func runAsync<T>(_ body: UncheckedBox<() throws -> T>) async -> T {
    do {
      return try await LawThread.run { UncheckedBox(try body.value()) }.value
    } catch {
      trap(error)
    }
  }

  /// Run an async definition that fails with E.
  public static func runFailingAsync<T, E: Error>(
    _ ability: String, _ convert: @escaping (Value) throws -> E,
    _ body: UncheckedBox<() throws -> T>
  ) async throws(E) -> T {
    let outcome: Result<UncheckedBox<T>, any Error>
    do {
      outcome = .success(try await LawThread.run { UncheckedBox(try body.value()) })
    } catch {
      outcome = .failure(error)
    }
    switch outcome {
    case .success(let value):
      return value.value
    case .failure(let raised as RaisedFailure) where raised.ability == ability:
      do {
        throw try convert(raised.failure)
      } catch let failure as E {
        throw failure
      } catch {
        trap(error)
      }
    case .failure(let error):
      trap(error)
    }
  }
}
