// Ordered finite rows for Swift Testing. Covers keep shared suffixes and
// mathematical ranges; each attempt materializes values in a fresh context.
// ref:DEC-planned-generation ref:DEC-native-property-frameworks

import Foundation
import LawSpecRuntime

public typealias FiniteFactory = @Sendable (SymbolContext) throws -> Value

public enum FiniteDomain: Sendable {
  case values([FiniteFactory])
  case integers(BigInt, BigInt)

  fileprivate var count: BigInt {
    switch self {
    case .values(let factories): return BigInt(factories.count)
    case .integers(let first, let last): return max(.zero, last - first + .one)
    }
  }

  fileprivate func factory(at index: BigInt) throws -> FiniteFactory {
    switch self {
    case .values(let factories):
      guard let position = index.exactly(Int.self), factories.indices.contains(position) else {
        throw LawSpecError("InvalidFiniteCaseIndex", index.description)
      }
      return factories[position]
    case .integers(let first, _):
      let value = first + index
      return { _ in .int(value) }
    }
  }
}

public indirect enum FiniteCover: Sendable {
  case copies(Int)
  case branches([(FiniteDomain, FiniteCover)])

  public func count() throws -> BigInt {
    switch self {
    case .copies(let count):
      guard count >= 0 else { throw LawSpecError("InvalidFiniteCover", "negative multiplicity") }
      return BigInt(count)
    case .branches(let branches):
      var total = BigInt.zero
      for (domain, suffix) in branches { total = total + domain.count * (try suffix.count()) }
      return total
    }
  }

  /// Select one row without expanding its predecessors, even in a huge range.
  public func factories(at index: BigInt) throws -> [FiniteFactory] {
    guard index >= .zero, index < (try count()) else {
      throw LawSpecError("InvalidFiniteCaseIndex", index.description)
    }
    return try row(index, [])
  }

  private func row(_ index: BigInt, _ prefix: [FiniteFactory]) throws -> [FiniteFactory] {
    switch self {
    case .copies: return prefix
    case .branches(let branches):
      var remaining = index
      for (domain, suffix) in branches {
        let suffixCount = try suffix.count()
        let size = domain.count * suffixCount
        if remaining < size {
          let factory = try domain.factory(at: remaining / suffixCount)
          return try suffix.row(remaining % suffixCount, prefix + [factory])
        }
        remaining = remaining - size
      }
      throw LawSpecError("InvalidFiniteCaseIndex", index.description)
    }
  }
}

/// The ordinal is the native runner's stable argument identity; factories
/// are executable case data and are never serialized or evaluated for display.
public struct FiniteCase: Sendable, Encodable, CustomStringConvertible {
  public let index: Int
  private let factories: [FiniteFactory]

  fileprivate init(_ index: Int, _ factories: [FiniteFactory]) {
    self.index = index
    self.factories = factories
  }

  public var description: String { "boundary \(index + 1)" }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(index)
  }

  public func context(_ law: String) -> String { law + " " + description }

  public func values(_ symbols: SymbolContext) throws -> [Value] {
    try factories.map { try $0(symbols) }
  }

  public func check(
    _ law: String, _ symbols: SymbolContext, _ body: ([Value]) throws -> Value
  ) throws {
    let inputs = try values(symbols)
    do {
      let result = try body(inputs)
      guard case .bool(true) = result else {
        throw LawSpecError("ContractFailed", Recorded.debug(result))
      }
    } catch {
      let rendered = inputs.map(Recorded.renderPlain).joined(separator: ", ")
      throw LawSpecError(
        "BoundaryFailed", "\(context(law)) (\(rendered)): \(error)",
        cause: String(describing: error))
    }
  }
}

/// Swift Testing requires a Sendable Collection. The compiler's finite cover
/// fits native collection indices; a larger caller-supplied cover is rejected
/// explicitly instead of truncating or reporting empty coverage.
public struct FiniteCases: RandomAccessCollection, Sendable {
  public typealias Index = Int
  public typealias Element = FiniteCase
  private let cover: FiniteCover
  public let endIndex: Int
  public let startIndex = 0

  public init(_ cover: FiniteCover) throws {
    let count = try cover.count()
    guard let size = count.exactly(Int.self) else {
      throw LawSpecError("FiniteCoverTooLarge", "case count does not fit a native collection index")
    }
    self.cover = cover
    self.endIndex = size
  }

  public subscript(position: Int) -> FiniteCase {
    precondition(position >= startIndex && position < endIndex)
    do {
      return FiniteCase(position, try cover.factories(at: BigInt(position)))
    } catch {
      preconditionFailure("validated finite cover became invalid: \(error)")
    }
  }

  public static func visit(_ cases: FiniteCases, _ body: (FiniteCase) throws -> Void) rethrows {
    for row in cases { try body(row) }
  }

  public func index(after index: Int) -> Int { index + 1 }
  public func index(before index: Int) -> Int { index - 1 }
}

/// A random-order unit expands case metadata, never law bodies or input values.
public enum InvocationGroup: Sendable {
  case fixed(String, String)
  case finite(String, String, FiniteCases)
}

public struct Invocation: Sendable, Encodable, CustomStringConvertible {
  public let law: String
  public let name: String
  private let argument: FiniteCase?

  private enum CodingKeys: String, CodingKey { case law, name, index }

  public var description: String {
    argument.map { name + " " + $0.description } ?? name
  }

  private var id: String { name + (argument.map { "#" + String($0.index) } ?? "") }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(law, forKey: .law)
    try container.encode(name, forKey: .name)
    try container.encodeIfPresent(argument?.index, forKey: .index)
  }

  public func finiteCase() throws -> FiniteCase {
    guard let argument else { throw LawSpecError("MissingFiniteCase", name) }
    return argument
  }

  /// Completion comes from the actual native case body. The host also requires
  /// the current Swift Testing aggregate report before accepting these rows.
  public func run(_ unit: String, _ body: () throws -> Void) throws {
    let fields: [String: Any] = ["unit": unit, "law": law, "name": name, "id": id]
    try InvocationReport.record(fields.merging(["event": "case-start"]) { _, new in new })
    let started = DispatchTime.now().uptimeNanoseconds
    do {
      try body()
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
      try InvocationReport.record(
        fields.merging([
          "event": "case-end", "status": "passed", "time": elapsed,
        ]) { _, new in new })
    } catch {
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
      try InvocationReport.record(
        fields.merging([
          "event": "case-end", "status": "failed", "time": elapsed,
          "failure": String(describing: error),
        ]) { _, new in new })
      throw error
    }
  }

  public static func expand(_ unit: String, _ groups: [InvocationGroup]) throws -> [Invocation] {
    var selected: Set<String>?
    if let encoded = ProcessInfo.processInfo.environment["LAWSPEC_SWIFT_LAWS"], !encoded.isEmpty {
      struct Selection: Decodable {
        let unit: String
        let name: String
      }
      let rows = try JSONDecoder().decode([Selection].self, from: Data(encoded.utf8))
      let names = Set(rows.filter { $0.unit == unit }.map(\.name))
      let known = Set(
        groups.map { group in
          switch group {
          case .fixed(let law, _), .finite(let law, _, _): return law
          }
        })
      if names.isEmpty { return [] }
      guard names.isSubset(of: known) else {
        throw LawSpecError("UnknownSwiftLawSelection", unit)
      }
      selected = names
    }
    let invocations = groups.flatMap { group -> [Invocation] in
      switch group {
      case .fixed(let law, let name):
        return selected?.contains(law) == false
          ? [] : [Invocation(law: law, name: name, argument: nil)]
      case .finite(let law, let name, let cases):
        return selected?.contains(law) == false
          ? [] : cases.map { Invocation(law: law, name: name, argument: $0) }
      }
    }
    try InvocationReport.record([
      "event": "plan", "unit": unit,
      "cases": invocations.map { ["law": $0.law, "name": $0.name, "id": $0.id] },
    ])
    return invocations
  }
}

private enum InvocationReport {
  private static let lock = NSLock()

  static func record(_ row: [String: Any]) throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["LAWSPEC_SWIFT_REPORT"], !path.isEmpty else { return }
    guard let token = environment["LAWSPEC_SWIFT_RUN"], !token.isEmpty else {
      throw LawSpecError("MissingSwiftRunIdentity")
    }
    var row = row
    row["version"] = 1
    row["run"] = token
    var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    data.append(10)
    lock.lock()
    defer { lock.unlock() }
    if !FileManager.default.fileExists(atPath: path) {
      guard FileManager.default.createFile(atPath: path, contents: nil) else {
        throw LawSpecError("SwiftReportUnavailable", path)
      }
    }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }
}
