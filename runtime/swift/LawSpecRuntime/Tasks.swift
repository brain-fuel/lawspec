// Cancellation scopes: a scope owns the work started beneath it, including
// nested scopes, and closing it cancels that work. A running thread cannot
// be killed, so cancellation is cooperative: work observes its scope, and a
// closed scope never waits for work that ignores it. Ambient context (the
// workflow runtime, the current scope) follows work onto the runtime's
// threads. ref:DEC-async-native-tasks ref:DEC-typed-core-boundary

import Foundation

/// Values each runtime thread sees, copied to the threads it starts.
public enum Ambient {
  private static let key = "lawspec.ambient"

  private final class Box {
    var values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }
  }

  private static var box: Box {
    if let found = Thread.current.threadDictionary[key] as? Box { return found }
    let made = Box([:])
    Thread.current.threadDictionary[key] = made
    return made
  }

  public static func get(_ name: String) -> Any? { box.values[name] }

  public static func set(_ name: String, _ value: Any?) { box.values[name] = value }

  /// This thread's values, to give another thread.
  public static func capture() -> [String: Any] { box.values }

  /// Take another thread's values.
  public static func restore(_ values: [String: Any]) { box.values = values }

  /// Run a body with a value set, restoring the previous one after.
  public static func with<T>(_ name: String, _ value: Any?, _ body: () throws -> T) rethrows -> T {
    let previous = get(name)
    set(name, value)
    defer { set(name, previous) }
    return try body()
  }
}

public enum Tasks {
  /// A cancellation scope.
  public final class Scope: @unchecked Sendable {
    public let parent: Scope?
    private var closed = false
    private let gate = NSLock()

    init(parent: Scope?) { self.parent = parent }

    /// Whether this scope, or one around it, was closed.
    public var isClosed: Bool {
      gate.lock()
      let mine = closed
      gate.unlock()
      return mine || (parent?.isClosed ?? false)
    }

    /// Cancel everything the scope owns.
    public func close() {
      gate.lock()
      closed = true
      gate.unlock()
    }
  }

  private static let currentKey = "lawspec.tasks.scope"

  /// The innermost scope, or nil outside any.
  public static func currentScope() -> Scope? { Ambient.get(currentKey) as? Scope }

  /// Run a body in a new scope, closing it (and cancelling its work) after.
  public static func withScope<T>(_ body: (Scope) throws -> T) rethrows -> T {
    let scope = Scope(parent: currentScope())
    defer { scope.close() }
    return try Ambient.with(currentKey, scope) { try body(scope) }
  }

  /// Fail if the current scope was closed.
  public static func check() throws {
    if currentScope()?.isClosed ?? false {
      throw Fail.with("Cancelled", "the work's scope was closed")
    }
  }
}
