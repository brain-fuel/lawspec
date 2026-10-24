// A reliable channel end a node owns: its protocol state, its retry timer
// and its reader. Giving up is an ordered frame that keeps retrying after
// the application leaves; an unused end can move to another node.
// ref:DEC-distribution-canonical-wire ref:DEC-sessions-by-construction

import Foundation

/// The bytes a reader gets, or why there are none.
public typealias Delivery = Result<[UInt8], NodeFailure>

public final class Endpoint: NodeService, @unchecked Sendable {
  private final class Reader {
    let ticket: Int64
    let respond: @Sendable (Delivery) -> Void
    var timer: NetworkTimer?

    init(ticket: Int64, respond: @escaping @Sendable (Delivery) -> Void) {
      self.ticket = ticket
      self.respond = respond
    }
  }

  private struct State {
    var channel: ChannelProtocol.State
    var reader: Reader?
    var taking: (@Sendable (Result<Void, NodeFailure>) -> Void)?
    var timer: NetworkTimer?
    var tickets: Int64 = 0
    var stopped = false
  }

  private let node: Node
  private let name: String
  public let address: String
  private let state: Locked<State>

  public init(_ node: Node, _ name: String, _ deadline: Int) throws {
    if deadline <= 0 { throw Fail.with("Channel", "invalid_deadline") }
    self.node = node
    self.name = name
    let box = Locked<Endpoint?>(nil)
    address = try node.registerReceiver(name) { frame in box.with { $0 }?.arrive(frame) }
    state = Locked(State(channel: try ChannelProtocol.create(address, Int64(deadline) * 1000)))
    box.with { $0 = self }
    node.adopt(self)
  }

  private static func now() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1000) }

  private static func fail(_ reason: String) -> LawSpecError { Fail.with("Channel", reason) }

  /// Settle waiters and the timer; return what to do outside the lock.
  private func wake(_ s: inout State) -> [() -> Void] {
    var actions = [() -> Void]()
    if let respond = s.taking {
      switch ChannelProtocol.takeStatus(s.channel, Endpoint.now()) {
      case .success(false): break
      case .success(true):
        s.taking = nil
        actions.append { respond(.success(())) }
      case .failure(let reason):
        s.taking = nil
        actions.append { respond(.failure(reason)) }
      }
    } else if let r = s.reader {
      let (result, next) = ChannelProtocol.receiveBody(s.channel)
      switch result {
      case .empty: break
      case .body(let b):
        s.channel = next
        s.reader = nil
        r.timer?.cancel()
        actions.append { r.respond(.success(b)) }
      case .failed(let reason):
        s.channel = next
        s.reader = nil
        r.timer?.cancel()
        actions.append { r.respond(.failure(NodeFailure(reason))) }
      }
    }
    let c = s.channel
    let active =
      c.failure == nil && c.moved == nil
      && (!c.unacked.isEmpty || s.taking != nil || (c.taking != nil && !c.taken)
        || (c.announcing && !c.confirmed && c.peer != nil))
    if active && s.timer == nil && !s.stopped {
      s.timer = NetworkTimer(10) { [weak self] in self?.tick() }
    } else if !active, let t = s.timer {
      t.cancel()
      s.timer = nil
    }
    return actions
  }

  private func update(
    _ transition: (ChannelProtocol.State) throws -> (ChannelProtocol.State, [Frame])
  ) throws {
    let (frames, actions) = try state.with { s in
      let (next, frames) = try transition(s.channel)
      s.channel = next
      return (frames, wake(&s))
    }
    for frame in frames { try? node.forward(frame) }
    for action in actions { action() }
  }

  private func tick() { try? update { try ChannelProtocol.tick($0, Endpoint.now()) } }

  private func arrive(_ frame: Frame) {
    try? update { (ChannelProtocol.accept($0, frame, Endpoint.now())) }
  }

  private func guarded<T>(_ operation: () throws -> T) throws -> T {
    do {
      return try operation()
    } catch let e as LawSpecError where e.code == "Channel" {
      throw e
    } catch let e as LawSpecError where e.code == "ChannelEndUnavailable" {
      throw Endpoint.fail("channel_end_unavailable")
    } catch {
      throw Endpoint.fail("invalid_operation")
    }
  }

  private func idle(_ s: State) throws {
    if s.taking != nil { throw Endpoint.fail("taking_in_progress") }
  }

  public func connect(_ peer: String) throws {
    try guarded {
      try state.with { try idle($0) }
      try update { try ChannelProtocol.connect($0, peer, Endpoint.now()) }
    }
  }

  public func send(_ bytes: [UInt8]) throws {
    try guarded {
      try state.with { try idle($0) }
      try update { try ChannelProtocol.send($0, bytes, Endpoint.now()) }
    }
  }

  public func abandon() { try? update { try ChannelProtocol.abandon($0, Endpoint.now()) } }

  /// Wait for the next value (timeout in ms, or none): its bytes, or why
  /// there is none.
  @discardableResult
  public func receiveAsync(_ timeout: Int?, _ respond: @escaping @Sendable (Delivery) -> Void)
    throws -> Int64
  {
    let ticket: Int64 = try state.with { s in
      try idle(s)
      if s.reader != nil { throw Endpoint.fail("already_receiving") }
      s.tickets += 1
      let r = Reader(ticket: s.tickets, respond: respond)
      s.reader = r
      if let ms = timeout {
        let ticket = s.tickets
        NetworkTimer.after(ms) { [weak self] in
          guard let self else { return }
          let fire: Bool = self.state.with { s in
            guard let current = s.reader, current.ticket == ticket else { return false }
            s.reader = nil
            return true
          }
          if fire { respond(.failure(NodeFailure("receive_timeout"))) }
        }
      }
      return s.tickets
    }
    try update { ($0, []) }
    return ticket
  }

  /// Wait for the next value's bytes.
  public func receive(_ timeout: Int?) throws -> Delivery {
    let result = Locked<Delivery?>(nil)
    let done = DispatchSemaphore(value: 0)
    try receiveAsync(timeout) { delivery in
      result.with { $0 = delivery }
      done.signal()
    }
    done.wait()
    return result.with { $0 }!
  }

  /// Stop waiting; the reader is not called.
  public func cancel(_ ticket: Int64) {
    state.with { s in
      if let r = s.reader, r.ticket == ticket {
        r.timer?.cancel()
        s.reader = nil
      }
    }
  }

  /// Offer this unused end to another node; the address that takes it.
  public func offer() throws -> String {
    try guarded {
      try state.with { s in
        try idle(s)
        if s.reader != nil { throw Endpoint.fail("already_receiving") }
        let (address, next) = try ChannelProtocol.offer(
          s.channel, Wire.hex(CryptoPrimitives.randomBytes(32)).uppercased())
        s.channel = next
        return address
      }
    }
  }

  /// Take an offered end into this fresh one, waiting until it arrives.
  public func take(_ offered: String) throws {
    let result = Locked<Result<Void, NodeFailure>?>(nil)
    let done = DispatchSemaphore(value: 0)
    try guarded {
      try state.with { s in
        try idle(s)
        if s.reader != nil { throw Endpoint.fail("already_receiving") }
        let c = s.channel
        if c.peer != nil || !c.unacked.isEmpty || c.expected != 0 || c.taking != nil {
          throw Endpoint.fail("end_not_fresh")
        }
        s.taking = { outcome in
          result.with { $0 = outcome }
          done.signal()
        }
      }
      try update { try ChannelProtocol.take($0, offered, Endpoint.now()) }
    }
    done.wait()
    if case .failure(let reason) = result.with({ $0 })! { throw Endpoint.fail(reason.reason) }
  }

  /// Destroy the end (a conversation ends with abandon).
  public func stop() {
    let (r, t) = state.with { s in
      s.stopped = true
      s.timer?.cancel()
      s.timer = nil
      let r = s.reader
      s.reader = nil
      let t = s.taking
      s.taking = nil
      return (r, t)
    }
    r?.respond(.failure(NodeFailure("endpoint_closed")))
    t?(.failure(NodeFailure("endpoint_closed")))
    node.unregister(name)
  }

  public func release() { stop() }
}
