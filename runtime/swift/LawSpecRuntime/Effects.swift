// Abilities in Swift: lexically scoped handlers, carried in the schema, and
// typed failures. A handler is the logical view of an ability's operations;
// native code sees the ability's generated protocol, and a native handler
// becomes a logical one through its generated bridge. State lives in cells
// owned by the scope that made the handler, so concurrent steps share it.
// ref:DEC-typed-core-boundary ref:DEC-swift-runtime-from-scratch

import Foundation

public enum Effects {
  /// An operation's clause: the schema in scope and the arguments to a result.
  public typealias Clause = @Sendable (Schema, [Value]) throws -> Value

  /// A stateful clause also takes the state, and gives back a pair of the
  /// result and the next state.
  public typealias StatefulClause = @Sendable (Schema, [Value], Value) throws -> Value

  /// Mutable state, read and replaced under a lock.
  public final class Cell: @unchecked Sendable {
    private var value: Value
    private let gate = NSRecursiveLock()
    public init(_ initial: Value) { value = initial }
    public func read() -> Value {
      gate.lock()
      defer { gate.unlock() }
      return value
    }
    public func write(_ next: Value) {
      gate.lock()
      defer { gate.unlock() }
      value = next
    }
    /// Run an update under the cell's lock.
    public func update<R>(_ change: (Value) throws -> (R, Value)) rethrows -> R {
      gate.lock()
      defer { gate.unlock() }
      let (result, next) = try change(value)
      value = next
      return result
    }
  }

  /// A log of the operations a recording handler saw, in order.
  public final class Log: @unchecked Sendable {
    private var entries: [(String, [Value])] = []
    private let gate = NSLock()
    public init() {}
    public func add(_ operation: String, _ arguments: [Value]) {
      gate.lock()
      defer { gate.unlock() }
      entries.append((operation, arguments))
    }
    public var calls: [(String, [Value])] {
      gate.lock()
      defer { gate.unlock() }
      return entries
    }
  }

  public indirect enum Handler: Sendable {
    case stateless([String: Clause])
    case stateful(Cell, [String: StatefulClause])
    case recording(Log, Handler)
  }

  /// A handler scope: it owns the handlers of several abilities made once in
  /// it, and is closed when its body ends.
  public final class Scope: @unchecked Sendable {
    private var made: [String: Handler] = [:]
    private let gate = NSRecursiveLock()
    public init() {}
    public func shared(_ key: String, _ make: () throws -> Handler) rethrows -> Handler {
      gate.lock()
      defer { gate.unlock() }
      if let h = made[key] { return h }
      let h = try make()
      made[key] = h
      return h
    }
  }

  /// A native protocol made from a logical handler keeps it, so the handler
  /// is recovered, with its state, when the native value crosses back.
  public protocol Origin: AnyObject {
    var originAbility: String { get }
    var originSymbols: SymbolContext { get }
    var originHandler: Handler { get }
    var originSchema: Schema { get }
  }

  private static func fail(_ code: String, _ detail: String = "") -> LawSpecError {
    Fail.with(code, detail)
  }

  /// A handler with no state.
  public static func stateless(_ clauses: [(String, Clause)]) -> Handler {
    .stateless(Dictionary(clauses, uniquingKeysWith: { $1 }))
  }

  /// A handler with state, from its start.
  public static func stateful(_ initial: Value, _ clauses: [(String, StatefulClause)]) -> Handler {
    .stateful(Cell(initial), Dictionary(clauses, uniquingKeysWith: { $1 }))
  }

  /// A handler that logs every operation, then runs another.
  public static func recording(_ inner: Handler) -> Handler { .recording(Log(), inner) }

  /// Handlers installed in a schema, overriding outer ones.
  public static func install(_ schema: Schema, _ handlers: [(String, Handler)]) -> Schema {
    var installed = schema
    for (key, h) in handlers { installed.handlers[key] = h }
    return installed
  }

  /// The handler of an ability in scope.
  public static func handler(_ schema: Schema, _ ability: String) throws -> Handler {
    guard let h = schema.handlers[ability] else { throw fail("MissingHandler", ability) }
    return h
  }

  /// Run a body in a new scope with handlers made by factories. A factory
  /// failing leaves no handler behind.
  public static func withScope<R>(
    _ schema: Schema, _ factories: [(String, (Schema) throws -> Handler)],
    _ body: (Schema) throws -> R
  ) throws -> R {
    var based = schema
    based.scope = Scope()
    let handlers = try factories.map { ($0.0, try $0.1(based)) }
    return try body(install(based, handlers))
  }

  /// A handler of several abilities is made once in a scope, so they share its
  /// state.
  public static func shared(_ schema: Schema, _ key: String, _ make: () throws -> Handler) throws
    -> Handler
  {
    guard let scope = schema.scope else { return try make() }
    return try scope.shared(key, make)
  }

  private static func clause<C>(_ clauses: [String: C], _ operation: String) throws -> C {
    guard let c = clauses[operation] else { throw fail("MissingHandlerOperation", operation) }
    return c
  }

  /// Run an operation of a handler.
  public static func invoke(
    _ h: Handler, _ schema: Schema, _ operation: String, _ arguments: [Value]
  ) throws -> Value {
    switch h {
    case .stateless(let clauses):
      return try clause(clauses, operation)(schema, arguments)
    case .stateful(let cell, let clauses):
      let run = try clause(clauses, operation)
      let identity = ObjectIdentifier(cell)
      if schema.effectPath.contains(identity) { throw fail("RecursiveHandlerCall", operation) }
      var inner = schema
      inner.effectPath = [identity] + schema.effectPath
      return try cell.update { state in
        let outcome = try run(inner, arguments, state)
        guard case .data(_, let pair) = outcome, pair.count == 2 else {
          throw fail("InvalidHandlerResult", "\(outcome)")
        }
        return (pair[0], pair[1])
      }
    case .recording(let log, let inner):
      log.add(operation, arguments)
      return try invoke(inner, schema, operation, arguments)
    }
  }

  /// Perform an operation of an ability through the handler in scope.
  public static func perform(
    _ schema: Schema, _ ability: String, _ operation: String, _ arguments: [Value]
  ) throws -> Value {
    try invoke(handler(schema, ability), schema, operation, arguments)
  }

  /// How many times a recording handler saw an operation (with arguments, if
  /// given).
  public static func countCalls(
    _ schema: Schema, _ ability: String, _ operation: String, _ arguments: [Value]?
  ) throws -> Value {
    guard case .recording(let log, _) = try handler(schema, ability) else {
      throw fail("RecordingRequired", ability)
    }
    let count = log.calls.filter { name, values in
      name == operation && (arguments.map { Scalar.equal(.list(values), .list($0)) } ?? true)
    }.count
    return .int(BigInt(count))
  }

  /// Raise a typed failure of a Fail ability.
  public static func raiseFailure(_ ability: String, _ failure: Value) throws -> Value {
    throw RaisedFailure(ability, failure)
  }

  /// Catch a typed failure: Right of the body's value, or Left of the failure.
  public static func attempt(
    _ ability: String, _ body: () throws -> Value, _ right: (Value) throws -> Value,
    _ left: (Value) throws -> Value
  ) throws -> Value {
    let outcome: Value
    do {
      outcome = try body()
    } catch let raised as RaisedFailure where raised.ability == ability {
      return try left(raised.failure)
    }
    return try right(outcome)
  }

  /// A native adapter's typed throw: its failure raised as the logical one.
  public static func ofThrown<T, E: Error>(
    _ ability: String, _ convert: (E) throws -> Value, _ body: () throws(E) -> T
  ) throws -> T {
    do {
      return try body()
    } catch {
      throw RaisedFailure(ability, try convert(error))
    }
  }

  /// The same, for an async adapter.
  public static func ofThrownAsync<T: Sendable, E: Error>(
    _ ability: String, _ convert: @escaping @Sendable (E) throws -> Value,
    _ body: @escaping @Sendable () async throws(E) -> T
  ) throws -> T {
    try Runtime.await {
      do throws(E) {
        return try await body()
      } catch {
        throw RaisedFailure(ability, try convert(error))
      }
    }
  }

  /// Errors of mapped native types become typed failures; the others pass.
  public static func nativeFailures(
    _ ability: String, _ body: () throws -> Value, _ mappings: [(any Error) throws -> Value?]
  ) throws -> Value {
    do {
      return try body()
    } catch let raised as RaisedFailure {
      throw raised
    } catch let failure as LawSpecError {
      throw failure
    } catch {
      for mapping in mappings {
        if let failure = try mapping(error) { throw RaisedFailure(ability, failure) }
      }
      throw error
    }
  }

  /// A mapping for nativeFailures: an error of type E becomes a failure.
  public static func mapError<E: Error>(_ type: E.Type, _ make: @escaping (E) throws -> Value) -> (
    any Error
  ) throws -> Value? {
    { error in
      guard let caught = error as? E else { return nil }
      return try make(caught)
    }
  }

  /// A logical failure crossing to native code: thrown as its native type,
  /// the typed throw its native form declares.
  public static func nativeTry<T, E: Error>(
    _ ability: String, _ convert: (Value) throws -> E, _ body: () throws -> T
  ) throws -> T {
    do {
      return try body()
    } catch let raised as RaisedFailure where raised.ability == ability {
      throw try convert(raised.failure)
    }
  }

  /// The handler behind a native protocol value, if it came from a logical one
  /// with the same symbols.
  public static func recover(
    _ native: Any, _ ability: String, _ symbols: SymbolContext, _ make: () throws -> Handler
  ) rethrows -> Handler {
    if let origin = native as? Origin, origin.originAbility == ability,
      origin.originSymbols === symbols
    {
      return origin.originHandler
    }
    return try make()
  }

  private static func stateCell(_ h: Handler) throws -> Cell {
    switch h {
    case .stateful(let cell, _): return cell
    case .recording(_, let inner): return try stateCell(inner)
    case .stateless: throw fail("StatelessHandler")
    }
  }

  /// A spec handler's state, through its native protocol value.
  public static func handlerState(_ native: Any) throws -> (Schema, Value) {
    guard let origin = native as? Origin else {
      throw fail("StatelessHandler", "a native handler has no LawSpec state")
    }
    return (origin.originSchema, try stateCell(origin.originHandler).read())
  }

  /// Replace a spec handler's state, through its native protocol value.
  public static func setHandlerState(_ native: Any, _ state: Value) throws {
    guard let origin = native as? Origin else {
      throw fail("StatelessHandler", "a native handler has no LawSpec state")
    }
    try stateCell(origin.originHandler).write(state)
  }

  /// A production handler made with a resource, asked for where no case has one.
  public static func resourceRequired(_ ability: String) throws -> Handler {
    throw fail("ResourceRequired", ability)
  }
}

// Calls of application code bound in lawspec.json. A bound function may or
// may not throw, and may or may not be async: passed as a value it converts
// to a throwing (or async throwing) function, so the generated call is the
// same either way.
extension Effects {
  public static func bound<R>(_ f: () throws -> R) throws -> R { try f() }
  public static func boundAsync<R>(_ f: () async throws -> R) async throws -> R { try await f() }
  public static func bound<A0, R>(_ f: (A0) throws -> R, _ a0: A0) throws -> R { try f(a0) }
  public static func boundAsync<A0, R>(_ f: (A0) async throws -> R, _ a0: A0) async throws -> R {
    try await f(a0)
  }
  public static func bound<A0, A1, R>(_ f: (A0, A1) throws -> R, _ a0: A0, _ a1: A1) throws -> R {
    try f(a0, a1)
  }
  public static func boundAsync<A0, A1, R>(_ f: (A0, A1) async throws -> R, _ a0: A0, _ a1: A1)
    async throws -> R
  { try await f(a0, a1) }
  public static func bound<A0, A1, A2, R>(
    _ f: (A0, A1, A2) throws -> R, _ a0: A0, _ a1: A1, _ a2: A2
  ) throws -> R { try f(a0, a1, a2) }
  public static func boundAsync<A0, A1, A2, R>(
    _ f: (A0, A1, A2) async throws -> R, _ a0: A0, _ a1: A1, _ a2: A2
  ) async throws -> R { try await f(a0, a1, a2) }
  public static func bound<A0, A1, A2, A3, R>(
    _ f: (A0, A1, A2, A3) throws -> R, _ a0: A0, _ a1: A1, _ a2: A2, _ a3: A3
  ) throws -> R { try f(a0, a1, a2, a3) }
  public static func boundAsync<A0, A1, A2, A3, R>(
    _ f: (A0, A1, A2, A3) async throws -> R, _ a0: A0, _ a1: A1, _ a2: A2, _ a3: A3
  ) async throws -> R { try await f(a0, a1, a2, a3) }
  public static func bound<A0, A1, A2, A3, A4, R>(
    _ f: (A0, A1, A2, A3, A4) throws -> R, _ a0: A0, _ a1: A1, _ a2: A2, _ a3: A3, _ a4: A4
  ) throws -> R { try f(a0, a1, a2, a3, a4) }
  public static func boundAsync<A0, A1, A2, A3, A4, R>(
    _ f: (A0, A1, A2, A3, A4) async throws -> R, _ a0: A0, _ a1: A1, _ a2: A2, _ a3: A3, _ a4: A4
  ) async throws -> R { try await f(a0, a1, a2, a3, a4) }
  public static func bound<A0, A1, A2, A3, A4, A5, R>(
    _ f: (A0, A1, A2, A3, A4, A5) throws -> R, _ a0: A0, _ a1: A1, _ a2: A2, _ a3: A3, _ a4: A4,
    _ a5: A5
  ) throws -> R { try f(a0, a1, a2, a3, a4, a5) }
  public static func boundAsync<A0, A1, A2, A3, A4, A5, R>(
    _ f: (A0, A1, A2, A3, A4, A5) async throws -> R, _ a0: A0, _ a1: A1, _ a2: A2, _ a3: A3,
    _ a4: A4, _ a5: A5
  ) async throws -> R { try await f(a0, a1, a2, a3, a4, a5) }
}
