// An owned in-memory packet transport with seeded loss, duplication and
// delay. Frames can overtake each other; reliability belongs to the node and
// the channel protocol above it, and no application code runs here.
// ref:DEC-distribution-canonical-wire ref:DEC-portable-seeded-generation

import Foundation

/// What happened to a frame sent on a memory network.
public struct MemoryEvent: Sendable {
  public let source: String
  public let to: String
  public let frame: [UInt8]
  public let outcome: String
  /// The delay slots of each copy (two when the frame was duplicated).
  public let delaySlots: [Int]
}

/// The options of an in-memory network: a seed for its faults, the chances
/// of losing and of duplicating a frame, the most a frame is delayed (in
/// seconds), and whether it records every frame.
public struct MemoryOptions: Sendable {
  public var seed: BigInt
  public var loss: Double
  public var duplicate: Double
  public var delay: Double
  public var record: Bool

  public init(
    seed: BigInt = .zero, loss: Double = 0, duplicate: Double = 0, delay: Double = 0,
    record: Bool = false
  ) {
    self.seed = seed
    self.loss = loss
    self.duplicate = duplicate
    self.delay = delay
    self.record = record
  }
}

/// A receiver of a packet's source and bytes.
public typealias PacketReceiver = @Sendable (String, [UInt8]) -> Void

public final class MemoryNetwork: @unchecked Sendable {
  private struct State {
    var random: Random.Seed
    var generation: Int64 = 0
    // Each registered address: its receiver and the generation it was registered at.
    var nodes: [String: (PacketReceiver, Int64)] = [:]
    var groups: [[String]]? = nil
    var trace: [MemoryEvent] = []
    var closed = false
  }

  private let options: MemoryOptions
  private let state: Locked<State>

  public init(_ options: MemoryOptions) throws {
    try Fail.require(
      options.loss >= 0 && options.loss <= 1, "MemoryNetwork", "invalid loss probability")
    try Fail.require(
      options.duplicate >= 0 && options.duplicate <= 1, "MemoryNetwork",
      "invalid duplicate probability")
    try Fail.require(
      options.delay >= 0 && options.delay <= 4_294_967, "MemoryNetwork", "invalid delay")
    self.options = options
    state = Locked(State(random: Random.seed(options.seed)))
  }

  /// mem://name for a bare name.
  public static func addressOf(_ name: String) throws -> String {
    if name.hasPrefix("mem://") { return name }
    try Fail.require(!name.isEmpty, "MemoryNetwork", "an empty node name")
    return "mem://" + name
  }

  private func chance(_ probability: Double, _ s: inout State) -> Bool {
    if probability <= 0 { return false }
    let (draw, next) = Random.below(BigInt(1 << 30), s.random)
    s.random = next
    return draw.doubleValue < probability * Double(1 << 30)
  }

  private func remember(_ event: MemoryEvent, _ s: inout State) {
    if options.record { s.trace.append(event) }
  }

  /// Register a receiver at an address: nil, or the reason it was refused.
  public func register(_ address: String, _ receiver: @escaping PacketReceiver) throws -> String? {
    let address = try MemoryNetwork.addressOf(address)
    return state.with { s in
      if s.closed { return "network_closed" }
      if s.nodes[address] != nil { return "already_registered" }
      s.generation += 1
      s.nodes[address] = (receiver, s.generation)
      return nil
    }
  }

  public func unregister(_ address: String) {
    guard let address = try? MemoryNetwork.addressOf(address) else { return }
    state.with { s in s.nodes[address] = nil }
  }

  /// Send bytes from one registered address to another: nil, or the reason it failed.
  public func send(_ source: String, _ destination: String, _ bytes: [UInt8]) throws -> String? {
    let source = try MemoryNetwork.addressOf(source)
    let destination = try MemoryNetwork.addressOf(destination)
    let outcome: Result<[(Int, Int64)], NetworkFailure> = state.with { s in
      func event(_ outcome: String, _ slots: [Int] = []) -> MemoryEvent {
        MemoryEvent(
          source: source, to: destination, frame: bytes, outcome: outcome, delaySlots: slots)
      }
      if s.closed || s.nodes[source] == nil { return .failure(NetworkFailure("not_node_owner")) }
      guard let (_, registered) = s.nodes[destination] else {
        remember(event("unreachable"), &s)
        return .failure(NetworkFailure("unreachable " + destination))
      }
      let reachable =
        s.groups.map { gs in gs.contains { $0.contains(source) && $0.contains(destination) } }
        ?? true
      if !reachable {
        remember(event("partitioned"), &s)
        return .success([])
      }
      if chance(options.loss, &s) {
        remember(event("lost"), &s)
        return .success([])
      }
      let copies = chance(options.duplicate, &s) ? 2 : 1
      var slots = [Int]()
      for _ in 0..<copies {
        let (slot, next) = Random.below(BigInt(1001), s.random)
        s.random = next
        slots.append(slot.exactly(Int.self) ?? 0)
      }
      remember(event("sent", slots), &s)
      return .success(slots.map { (Int((Double($0) * options.delay).rounded(.up)), registered) })
    }
    switch outcome {
    case .failure(let reason): return reason.reason
    case .success(let copies):
      for (delay, registered) in copies {
        let deliver: @Sendable () -> Void = { [self] in
          let receiver: PacketReceiver? = state.with { s in
            if let (r, g) = s.nodes[destination], g == registered, !s.closed { return r }
            return nil
          }
          receiver?(source, bytes)
        }
        if delay <= 0 {
          DispatchQueue.global().async(execute: deliver)
        } else {
          NetworkTimer.after(delay, deliver)
        }
      }
      return nil
    }
  }

  /// Only nodes in one group reach each other until healed.
  public func partition(_ groups: [[String]]) throws {
    let addressed = try groups.map { try $0.map(MemoryNetwork.addressOf) }
    state.with { s in s.groups = addressed }
  }

  public func heal() { state.with { s in s.groups = nil } }

  /// Every frame sent, in order, when recording.
  public func recorded() -> [[UInt8]] { state.with { s in s.trace.map(\.frame) } }

  public func trace() -> [MemoryEvent] { state.with { s in s.trace } }

  public func close() {
    state.with { s in
      s.closed = true
      s.nodes.removeAll()
    }
  }
}

/// A failure's reason, as a transport reports it.
struct NetworkFailure: Error {
  let reason: String
  init(_ reason: String) { self.reason = reason }
}
