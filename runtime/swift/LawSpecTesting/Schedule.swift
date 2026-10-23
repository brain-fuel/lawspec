// How a harness runs a unit's laws on Swift Testing: `order random` runs a
// unit's tests in an order the run's seed chooses (the same seed, the same
// order), and `parallel` lets them run at once, while other units' tests run
// one at a time. ref:REQ-harness-units ref:DEC-portable-seeded-generation

import CryptoKit
import Foundation
import LawSpecRuntime

public enum Schedule {
  private static let chosen = BigInt(UInt64.random(in: 0...UInt64.max))

  /// The run's seed for ordering: LAWSPEC_SEED, or one chosen once per run.
  public static func seed() -> BigInt {
    if let text = ProcessInfo.processInfo.environment["LAWSPEC_SEED"], !text.isEmpty,
      let s = BigInt(text)
    {
      return s
    }
    return chosen
  }

  /// Items in the order a seed chooses for a unit: by the hash of the seed,
  /// the unit and each item's position.
  public static func order<T>(_ unitName: String, _ items: [T]) -> [T] {
    let s = seed()
    FileHandle.standardError.write(
      Data("order random seed \(s) (\(unitName)): LAWSPEC_SEED=\(s) replays this order\n".utf8))
    let keyed = items.enumerated().map { i, item -> ([UInt8], Int, T) in
      let key = Array(
        SHA256.hash(data: Data((s.description + "\u{0}" + unitName + "\u{0}" + String(i + 1)).utf8))
      )
      return (key, i, item)
    }
    return keyed.sorted { a, b in
      let c = Scalar.compareBytes(a.0, b.0)
      return c != 0 ? c < 0 : a.1 < b.1
    }.map { $0.2 }
  }
}
