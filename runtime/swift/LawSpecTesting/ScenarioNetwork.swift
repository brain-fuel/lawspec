// Scenario values use the same canonical frames, reliable endpoints and
// mailbox receipts as native distribution. Only causal metadata stays beside
// the transport: channel clocks follow sequence order, and mailbox clocks
// follow the actual source/request identity, even after reordering.
// ref:DEC-distribution-canonical-wire ref:DEC-stateful-models-linearizability

import Foundation
import LawSpecRuntime

/// A channel end (channel, side) or a mailbox of a scenario.
public enum ScenarioDestination: Hashable, Sendable {
  case endOf(String, Int)
  case mailboxOf(String)
}

/// What a scenario sends: a value, or a channel end it hands over.
public enum ScenarioPayload: Sendable {
  case plain(Value)
  case moved(String, Int)
}

/// Why a scenario hub or network request failed.
public struct ScenarioFault: Error, Sendable {
  public let reason: String
  public init(_ reason: String) { self.reason = reason }
}

/// A vector clock: each process's count of steps.
public typealias ScenarioClock = [String: Int64]

/// A mailbox request's identity, set once the request is made.
final class RequestCell: @unchecked Sendable {
  var identity: UInt64 = 0
}

/// What the network's services report, posted to the scenario's hub.
enum ScenarioIncoming: @unchecked Sendable {
  case channelResult(ScenarioDestination, Int64, Result<[UInt8], NodeFailure>)
  case mailFrame(ScenarioDestination, Node, Frame)
  case mailReply(RequestCell, Result<(Int, [UInt8]), NodeFailure>)
}

/// What a report means for the hub's queues.
enum ScenarioOutcome {
  case delivered(ScenarioDestination, ScenarioPayload, ScenarioClock)
  case lost(ScenarioDestination, ScenarioPayload)
  case gone(ScenarioDestination)
}

/// Frame counts of a run over the network.
public struct ScenarioStats: Sendable {
  public let frames: Int
  public let lost: Int
  public let duplicated: Int
  public let pendingRequests: Int
}

/// The network of one scenario run: a seeded faulty memory network, a node per
/// channel end and two per mailbox. Only the hub calls it, one call at a time.
final class ScenarioNetwork: @unchecked Sendable {
  private final class EndEntry {
    let endpoint: Endpoint
    var sends: [Descriptors.Descriptor]
    var receives: [Descriptors.Descriptor]
    var clocks: [(ScenarioPayload, ScenarioClock)] = []
    var ticket: Int64?
    init(
      _ endpoint: Endpoint, _ sends: [Descriptors.Descriptor], _ receives: [Descriptors.Descriptor]
    ) {
      self.endpoint = endpoint
      self.sends = sends
      self.receives = receives
    }
  }

  private struct Box {
    let sender: Node
    let address: String
    let type: Descriptors.Descriptor
  }

  private struct Flight {
    let destination: ScenarioDestination
    let value: ScenarioPayload
    let clock: ScenarioClock
  }

  private struct FlightKey: Hashable {
    let source: String
    let identity: UInt64
  }

  private static func fail(_ reason: String) -> LawSpecError {
    Fail.with("ScenarioNetwork", reason)
  }

  private static func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw fail(reason) }
  }

  private static func unquote(_ d: Descriptors.Descriptor) throws -> String {
    switch d {
    case .quoted(let q), .atom(let q): return q
    default: throw fail("invalid_wire")
    }
  }

  private let table: Descriptors.Table
  private let network: MemoryNetwork
  private let deadline: Int
  private let post: @Sendable (ScenarioIncoming) -> Void
  private var nodes: [Node] = []
  private var ends: [ScenarioDestination: EndEntry] = [:]
  private var boxes: [ScenarioDestination: Box] = [:]
  private var flights: [FlightKey: Flight] = [:]
  private var pending: [UInt64: ((Result<Void, ScenarioFault>) -> Void, FlightKey)] = [:]

  init(
    _ channels: [String], _ mailboxes: [String], _ wire: [Descriptors.Descriptor]?, _ shake: BigInt,
    _ faults: (MemoryOptions) -> MemoryOptions, _ deadline: Int,
    _ post: @escaping @Sendable (ScenarioIncoming) -> Void
  ) throws {
    let forms: [Descriptors.Descriptor]
    if let wire {
      forms = wire
    } else if channels.isEmpty && mailboxes.isEmpty {
      forms = []
    } else {
      throw Self.fail("scenario_wire_required")
    }
    var steps: [String: [Descriptors.Descriptor]] = [:]
    var types: [String: Descriptors.Descriptor] = [:]
    var table = Descriptors.Table()
    for form in forms {
      guard case .forms(let parts) = form, let head = parts.first, case .atom(let key) = head else {
        continue
      }
      if key == "channel", parts.count >= 2 {
        steps[try Self.unquote(parts[1])] = Array(parts.dropFirst(2))
      }
      if key == "mailbox", parts.count == 3 { types[try Self.unquote(parts[1])] = parts[2] }
      if key == "data", parts.count >= 2 { table[try Self.unquote(parts[1])] = form }
    }
    try Self.require(steps.keys.sorted() == channels.sorted(), "channel_wire_required")
    try Self.require(types.keys.sorted() == mailboxes.sorted(), "mailbox_wire_required")
    self.table = table
    self.deadline = deadline
    self.post = post
    let defaults = MemoryOptions(
      seed: shake ^ BigInt(UInt64(0x7f4a_7c15_9e37_79b9)), loss: 0.1, duplicate: 0.1, delay: 0.002,
      record: true)
    network = try MemoryNetwork(faults(defaults))
    for name in channels {
      let a = try addEnd(name, 0, steps[name]!)
      let b = try addEnd(name, 1, steps[name]!)
      try b.connect(a.address)
    }
    for name in mailboxes.sorted() {
      let owner = try addNode()
      let sender = try addNode()
      let destination = ScenarioDestination.mailboxOf(name)
      let address = try owner.registerReceiver("mail") { frame in
        post(.mailFrame(destination, owner, frame))
      }
      boxes[destination] = Box(sender: sender, address: address, type: types[name]!)
    }
  }

  private func addNode() throws -> Node {
    let node = try Node(
      Transports.insecureMemoryForTests(network, "scenario-\(nodes.count)"), NetworkConfig.empty)
    nodes.append(node)
    return node
  }

  private func listen(_ destination: ScenarioDestination, _ entry: EndEntry) throws {
    // The callback may come before the ticket is known; the hub reads it later.
    let ticket = Locked<Int64>(0)
    let post = self.post
    let made = try entry.endpoint.receiveAsync(nil) { result in
      post(.channelResult(destination, ticket.with { $0 }, result))
    }
    ticket.with { $0 = made }
    entry.ticket = made
  }

  private func addEnd(_ name: String, _ side: Int, _ ss: [Descriptors.Descriptor]) throws
    -> Endpoint
  {
    let node = try addNode()
    let endpoint = try Endpoint(node, "end", deadline)
    let verbs: [(Bool, Descriptors.Descriptor)] = try ss.map { s in
      guard case .forms(let parts) = s, parts.count == 2, case .atom(let verb) = parts[0] else {
        throw Self.fail("invalid_wire")
      }
      return (verb == "send", parts[1])
    }
    let entry = EndEntry(
      endpoint, verbs.filter { $0.0 == (side == 0) }.map { $0.1 },
      verbs.filter { $0.0 != (side == 0) }.map { $0.1 })
    ends[.endOf(name, side)] = entry
    try listen(.endOf(name, side), entry)
    return endpoint
  }

  private func isEnd(_ d: Descriptors.Descriptor) -> Bool {
    if case .forms(let parts) = d, parts.count == 1, case .atom("end") = parts[0] { return true }
    return false
  }

  private func encode(_ d: Descriptors.Descriptor, _ payload: ScenarioPayload) throws -> [UInt8] {
    switch payload {
    case .moved(let name, let side) where isEnd(d):
      try Self.require(ends[.endOf(name, side)] != nil, "unknown_delegated_end")
      return try Descriptors.encode(.forms([.atom("text")]), .text("\(name)#\(side)"), [:])
    case .plain(let value):
      return try Descriptors.encode(d, value, table)
    default:
      throw Self.fail("invalid_payload")
    }
  }

  private func decode(_ d: Descriptors.Descriptor, _ bytes: [UInt8]) throws -> ScenarioPayload {
    guard isEnd(d) else { return .plain(try Descriptors.decode(d, bytes, table)) }
    guard case .text(let address) = try Descriptors.decode(.forms([.atom("text")]), bytes, [:]),
      let at = address.lastIndex(of: "#"), let side = Int(address[address.index(after: at)...])
    else {
      throw Self.fail("unknown_delegated_end")
    }
    let name = String(address[..<at])
    try Self.require(ends[.endOf(name, side)] != nil, "unknown_delegated_end")
    return .moved(name, side)
  }

  /// Send from an end, or to a mailbox (whose reply comes later): whether
  /// the send is complete now.
  func send(
    _ destination: ScenarioDestination, _ payload: ScenarioPayload, _ clock: ScenarioClock,
    _ reply: @escaping (Result<Void, ScenarioFault>) -> Void
  ) throws -> Bool {
    switch destination {
    case .endOf(let name, let side):
      let entry = ends[destination]!
      guard let d = entry.sends.first else { throw Self.fail("protocol_complete") }
      try entry.endpoint.send(try encode(d, payload))
      entry.sends.removeFirst()
      ends[.endOf(name, 1 - side)]!.clocks.append((payload, clock))
      return true
    case .mailboxOf:
      let box = boxes[destination]!
      let bytes = try encode(box.type, payload)
      let cell = RequestCell()
      let post = self.post
      let identity = try box.sender.requestAsync(box.address, "mail", bytes, deadline) { result in
        post(.mailReply(cell, result))
      }
      cell.identity = identity
      let key = FlightKey(source: box.sender.address, identity: identity)
      flights[key] = Flight(destination: destination, value: payload, clock: clock)
      pending[identity] = (reply, key)
      return false
    }
  }

  func abandon(_ destination: ScenarioDestination) {
    if case .endOf = destination { ends[destination]?.endpoint.abandon() }
  }

  /// What an incoming report means.
  func event(_ incoming: ScenarioIncoming) throws -> [ScenarioOutcome] {
    switch incoming {
    case .channelResult(let destination, let ticket, let result):
      guard let entry = ends[destination], entry.ticket == ticket else { return [] }
      switch result {
      case .success(let bytes):
        guard let d = entry.receives.first else { throw Self.fail("protocol_complete") }
        let (_, clock) = entry.clocks.removeFirst()
        let value = try decode(d, bytes)
        entry.receives.removeFirst()
        try listen(destination, entry)
        return [.delivered(destination, value, clock)]
      case .failure:
        let lost = entry.clocks.map { ScenarioOutcome.lost(destination, $0.0) }
        entry.clocks.removeAll()
        entry.ticket = nil
        return lost + [.gone(destination)]
      }
    case .mailFrame(let destination, let owner, let frame):
      let key = FlightKey(source: frame.source, identity: frame.id)
      if let flight = flights[key], flight.destination == destination, frame.kind == "mail" {
        let value = ScenarioPayload.plain(
          try Descriptors.decode(boxes[destination]!.type, frame.payload, table))
        try owner.reply(frame.source, frame.id, 0, [])
        flights[key] = nil
        return [.delivered(destination, value, flight.clock)]
      }
      if frame.id != 0 {
        try owner.reply(frame.source, frame.id, 3, Array("not a scenario mailbox request".utf8))
      }
      return []
    case .mailReply(let cell, let result):
      return replied(cell.identity, result)
    }
  }

  /// A mailbox reply, by the request identity it answers.
  private func replied(_ identity: UInt64, _ result: Result<(Int, [UInt8]), NodeFailure>)
    -> [ScenarioOutcome]
  {
    guard let (reply, key) = pending[identity] else { return [] }
    pending[identity] = nil
    switch result {
    case .success(let (status, body)) where status == 0 && body.isEmpty: reply(.success(()))
    case .success(let (status, _)):
      reply(.failure(ScenarioFault("mailbox_send_failed status \(status)")))
    case .failure(let failure):
      reply(.failure(ScenarioFault("mailbox_send_failed \(failure.reason)")))
    }
    // A timed-out request may never have arrived: release what it carried.
    guard let flight = flights[key] else { return [] }
    flights[key] = nil
    return [.lost(flight.destination, flight.value)]
  }

  func stats() -> ScenarioStats {
    let trace = network.trace()
    return ScenarioStats(
      frames: trace.count, lost: trace.filter { $0.outcome == "lost" }.count,
      duplicated: trace.filter { $0.delaySlots.count == 2 }.count, pendingRequests: pending.count)
  }

  func close() {
    for (reply, _) in pending.values { reply(.failure(ScenarioFault("network_closed"))) }
    pending.removeAll()
    for node in nodes { node.close() }
    network.close()
  }
}
