// Running a law's property: LawSpec's generation plan draws each case from
// the run's seed at a growing size, and the first failure shrinks along its
// shrink tree, so every candidate stays inside the law's domain. One seed per
// run is printed with any failure, and LAWSPEC_SEED replays it.
// ref:DEC-swift-property-library ref:DEC-never-pass-vacuously

import Foundation
import LawSpecRuntime

public enum Property {
  /// How many cases to run, how many discards the run may take, and how many
  /// shrink steps a failure may take.
  public struct Settings {
    public let cases: Int
    public let maxAttempts: Int
    public let maxShrinks: Int
  }

  /// The run's seed: LAWSPEC_SEED, or a fresh one.
  public static func runSeed() -> BigInt {
    if let text = ProcessInfo.processInfo.environment["LAWSPEC_SEED"], !text.isEmpty,
      let seed = BigInt(text)
    {
      return seed
    }
    return BigInt(Int64.random(in: Int64.min...Int64.max))
  }

  private static func render(_ values: [Value]) -> String {
    "(" + values.map(Recorded.renderPlain).joined(separator: ", ") + ")"
  }

  /// The largest size a case draws at. The size grows linearly from 0 to
  /// this over the run's cases, and with each discard too, so a domain that
  /// small draws rarely meet is reached at larger sizes.
  private static let maxSize = 100

  /// A failure of the harness itself ends the run: it is neither a
  /// counterexample nor shrunk.
  private static func isAbort(_ error: any Error) -> Bool {
    guard let failure = error as? LawSpecError else { return false }
    return failure.code == "StrategyOutsideRefinement" || failure.code == "StrategyDiscards"
  }

  private enum Outcome {
    case passed
    case failed(any Error)
    case aborted(any Error)
  }

  private static func attempt(_ property: ([Value]) throws -> Value, _ values: [Value]) -> Outcome {
    do {
      switch try property(values) {
      case .bool(true): return .passed
      case .bool(false): return .failed(LawSpecError("PropertyFalse"))
      case let other: return .failed(LawSpecError("NonBooleanProperty", Recorded.debug(other)))
      }
    } catch {
      return isAbort(error) ? .aborted(error) : .failed(error)
    }
  }

  /// Check a property over a generator of its inputs.
  public static func check(
    _ label: String, _ settings: Settings, _ gen: Gen<[Value]>,
    _ property: ([Value]) throws -> Value
  ) throws {
    let seed = runSeed()
    let width = settings.maxShrinks * 4
    var state = Random.seed(seed)
    var passed = 0
    var discards = 0
    while passed < settings.cases {
      let size = Swift.min(maxSize, (passed + discards) * maxSize / Swift.max(1, settings.cases))
      let (caseSeed, following) = Random.split(state)
      state = following
      let drawn: Tree<[Value]>?
      do {
        drawn = try gen.generate(caseSeed, size)
      } catch {
        throw error
      }
      guard let tree = drawn?.limit(settings.maxShrinks, width) else {
        discards += 1
        if discards > settings.maxAttempts {
          throw Harness.abort(
            "CannotSatisfy",
            "\(label): no input satisfied the law's domain after \(settings.maxAttempts) attempts (\(passed) passing case(s); seed \(seed))"
          )
        }
        continue
      }
      switch attempt(property, tree.value) {
      case .passed:
        passed += 1
      case .aborted(let error):
        throw error
      case .failed(let error):
        var current = tree
        var failure = error
        var shrinks = 0
        var aborted: (any Error)? = nil
        shrinking: while true {
          let candidates = (try? current.children()) ?? []
          for child in candidates {
            switch attempt(property, child.value) {
            case .failed(let e):
              current = child
              failure = e
              shrinks += 1
              continue shrinking
            case .aborted(let e):
              aborted = e
              break shrinking
            case .passed:
              continue
            }
          }
          break
        }
        if let e = aborted { throw e }
        let message =
          "\(label) failed after \(passed) passing case(s) and \(shrinks) shrink(s): counterexample \(render(current.value)); "
          + "seed \(seed) (LAWSPEC_SEED=\(seed) replays it)\n\(failure)"
        throw LawSpecError("PropertyFailed", message, cause: "\(failure)")
      }
    }
  }

  /// A law's generation settings.
  public static func settings(_ cases: Int, _ attempts: Int, _ shrinks: Int) -> Settings {
    Settings(cases: cases, maxAttempts: attempts, maxShrinks: shrinks)
  }

  /// What generation reads: the schema, the case's symbols and the discard budget.
  public static func generation(_ schema: Schema, _ symbols: SymbolContext, _ attempts: Int)
    -> Generators.Context
  {
    Generators.Context(schema: schema, symbols: symbols, factories: [:], attempts: attempts)
  }

  /// As generation, with the application's generators (bound in lawspec.json)
  /// in place of the built-in ones for their types.
  public static func generationWith(
    _ schema: Schema, _ symbols: SymbolContext, _ attempts: Int,
    _ factories: [(String, Generators.Factory)]
  ) -> Generators.Context {
    Generators.Context(
      schema: schema, symbols: symbols, factories: Dictionary(factories, uniquingKeysWith: { $1 }),
      attempts: attempts)
  }

  /// Each boundary case, in order; the first that fails names its position.
  public static func boundaries(
    _ label: String, _ cases: [[Value]], _ law: ([Value]) throws -> Value
  ) throws {
    for (i, values) in cases.enumerated() {
      do {
        let result = try law(values)
        guard case .bool(true) = result else {
          throw LawSpecError(
            "ContractFailed", "\(label) boundary \(i) returned \(Recorded.debug(result))")
        }
      } catch let failure as LawSpecError {
        throw LawSpecError(
          "BoundaryFailed", "\(label) boundary \(i) \(render(values)): \(failure)",
          cause: "\(failure)")
      }
    }
  }

  /// A strategy's value must lie inside the input's refinement.
  public static func checkDrawn(_ strategy: String, _ input: String, _ value: Value, _ holds: Bool)
    throws -> Value
  {
    if holds { return value }
    throw Harness.abort(
      "StrategyOutsideRefinement",
      "strategy \(strategy) produced \(Recorded.renderPlain(value)) for \(input), outside the input's refinement"
    )
  }

  /// A strategy's draw that keeps only values a predicate accepts.
  public static func suchThat(
    _ strategy: String, _ predicate: @escaping (Value) throws -> Bool, _ limit: Int,
    _ gen: Gen<Value>
  ) -> Gen<Value> {
    gen.suchThat(predicate, limit) {
      throw Harness.abort("StrategyDiscards", "strategy \(strategy) discarded \(limit) values")
    }
  }
}
