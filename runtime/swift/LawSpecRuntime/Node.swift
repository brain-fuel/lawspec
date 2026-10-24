// A node: named entities reached by frames, and reliable request and reply
// over a transport. Requests are deduplicated by sender and identity, even
// while their handler runs, and retried until answered or out of time.
// Handlers run on threads the node owns. Status codes: 0 ok, 1 failed,
// 2 stopped, 3 rejected.
// ref:DEC-distribution-canonical-wire

import Foundation

/// Something registered at a node under a name: a handler, whose answer the
/// node sends as the reply, or a receiver that answers later with reply.
public enum Entity: Sendable {
  case handler(@Sendable (Frame) throws -> (Int, [UInt8]))
  case receiver(@Sendable (Frame) -> Void)
}

/// A reply's status and body, or why there was none.
public typealias Reply = Result<(Int, [UInt8]), NodeFailure>

/// Why a request got no reply.
public struct NodeFailure: Error, Sendable {
  public let reason: String
  public init(_ reason: String) { self.reason = reason }
}

/// Something a node closes when it closes.
public protocol NodeService: AnyObject, Sendable {
  /// Stop the service: its node is closing.
  func release()
}

public final class Node: @unchecked Sendable {
  private struct Seen {
    var response: [UInt8]?
    let entity: String
    let fingerprint: [UInt8]
  }

  private struct SeenKey: Hashable {
    let source: String
    let id: UInt64
  }

  private enum Arrival {
    case resend([UInt8])
    case ignore
    case missing
    case dispatch(Entity)
  }

  private final class Pending {
    let peer: String
    let deadline: Date
    let respond: @Sendable (Reply) -> Void
    var timer: NetworkTimer?

    init(peer: String, deadline: Date, respond: @escaping @Sendable (Reply) -> Void) {
      self.peer = peer
      self.deadline = deadline
      self.respond = respond
    }
  }

  private struct State {
    var entities: [String: Entity] = [:]
    var seen: [SeenKey: Seen] = [:]
    var pending: [UInt64: Pending] = [:]
    var services: [any NodeService] = []
    var jobs = 0
    var closed = false
    var nextId: UInt64
  }

  private let state: Locked<State>
  private var secure: SecureLayer?
  private var raw: (any PacketTransport)?

  public init(_ transport: Transport, _ options: NetworkOptions) throws {
    var first = UInt64(0)
    for b in CryptoPrimitives.randomBytes(8) { first = first << 8 | UInt64(b) }
    state = Locked(State(nextId: options.firstId ?? ((first & ((1 << 61) - 1)) + 1)))
    let receive: PacketReceiver = { [weak self] _, bytes in self?.packet(bytes) }
    if case .memory(_, _, true) = transport {
      raw = try Transports.open(transport, receive)
    } else {
      secure = try SecureLayer(transport, options, receive)
    }
  }

  private static func fail(_ reason: String) -> LawSpecError { Fail.with("Network", reason) }

  /// The node's address: mem://name, tcp://host:port or http://host:port.
  public var address: String { secure?.address ?? raw!.address }

  /// The fingerprint of the node's identity (secure nodes only).
  public func identity() throws -> String {
    guard let secure else { throw Node.fail("insecure_node") }
    return secure.fingerprint
  }

  private func fingerprint(_ frame: Frame) -> [UInt8] {
    CryptoPrimitives.sha3(
      (try? Wire.encode(frame.kind, frame.to, frame.source, frame.id, frame.payload)) ?? [])
  }

  private func wire(_ peer: String, _ bytes: [UInt8]) -> String? {
    if let secure { return secure.send(peer, bytes) }
    return raw!.send(peer, bytes)
  }

  @discardableResult
  private func transmit(_ frame: Frame) throws -> String? {
    let (peer, name) = try Wire.splitAddress(frame.to)
    let source = frame.source.isEmpty ? address : frame.source
    return wire(peer, try Wire.encode(frame.kind, name, source, frame.id, frame.payload))
  }

  private func validate(_ frame: Frame) throws {
    do {
      _ = try Wire.splitAddress(frame.to)
      _ = try Wire.encode(frame.kind, "", frame.source, frame.id, frame.payload)
    } catch {
      throw Node.fail("invalid_frame")
    }
  }

  private func sendReply(_ source: String, _ identity: UInt64, _ payload: [UInt8]) {
    _ = try? transmit(
      Frame(kind: "reply", to: source + "/", source: "", id: identity, payload: payload))
  }

  private func answer(_ key: SeenKey, _ status: Int, _ body: [UInt8]) {
    let payload = [UInt8(truncatingIfNeeded: status)] + body
    let send: Bool = state.with { s in
      guard var entry = s.seen[key], entry.response == nil else { return false }
      entry.response = payload
      s.seen[key] = entry
      return true
    }
    if send { sendReply(key.source, key.id, payload) }
  }

  private func finish(_ identity: UInt64, _ result: Reply?) {
    let found: Pending? = state.with { s in
      guard let p = s.pending.removeValue(forKey: identity) else { return nil }
      p.timer?.cancel()
      return p
    }
    if let p = found, let r = result { p.respond(r) }
  }

  /// A packet from the transport.
  func packet(_ bytes: [UInt8]) {
    if let frame = Wire.read(bytes) { arrive(frame) }
  }

  private func arrive(_ frame: Frame) {
    if frame.kind == "reply" {
      guard let status = frame.payload.first else { return }
      let matches = state.with { s in s.pending[frame.id]?.peer == frame.source }
      if matches { finish(frame.id, .success((Int(status), Array(frame.payload.dropFirst())))) }
      return
    }
    let key = SeenKey(source: frame.source, id: frame.id)
    let action: Arrival = state.with { s in
      if frame.id != 0, let entry = s.seen[key] {
        if fingerprint(frame) != entry.fingerprint {
          return .resend([3] + Array("a request identity was reused for different content".utf8))
        }
        if let response = entry.response { return .resend(response) }
        return .ignore
      }
      guard let entity = s.entities[frame.to] else {
        if frame.id == 0 { return .ignore }
        s.seen[key] = Seen(response: nil, entity: frame.to, fingerprint: fingerprint(frame))
        return .missing
      }
      if frame.id != 0 {
        s.seen[key] = Seen(response: nil, entity: frame.to, fingerprint: fingerprint(frame))
      }
      return .dispatch(entity)
    }
    switch action {
    case .resend(let payload): sendReply(frame.source, frame.id, payload)
    case .ignore: return
    case .missing: answer(key, 3, Array(("nothing is registered as " + frame.to).utf8))
    case .dispatch(.receiver(let receive)): receive(frame)
    case .dispatch(.handler(let handle)):
      state.with { $0.jobs += 1 }
      LawThread.start { [self] in
        var status: Int
        var body: [UInt8]
        do {
          (status, body) = try handle(frame)
          if status < 0 || status > 255 { (status, body) = (1, Array("invalid reply".utf8)) }
        } catch {
          (status, body) = (1, Array(Node.message(error).utf8))
        }
        if frame.id != 0 { answer(key, status, body) }
        state.with { $0.jobs -= 1 }
      }
    }
  }

  /// An error's message, as a failed reply carries it.
  static func message(_ error: any Error) -> String {
    if let e = error as? LawSpecError {
      return e.detail.isEmpty ? e.code : e.code + ": " + e.detail
    }
    return String(describing: error)
  }

  private func register(_ name: String, _ entity: Entity) throws -> String {
    if name.isEmpty || name.contains("/") { throw Node.fail("invalid_entity_name") }
    try state.with { s in
      if s.closed { throw Node.fail("node_closed") }
      if s.entities[name] != nil { throw Node.fail("already_registered " + name) }
      s.entities[name] = entity
    }
    return address + "/" + name
  }

  /// Serve requests to a name with a handler of each frame; its answer is
  /// the reply's status and body. The entity's address.
  @discardableResult
  public func registerHandler(
    _ name: String, _ handler: @escaping @Sendable (Frame) throws -> (Int, [UInt8])
  ) throws -> String {
    try register(name, .handler(handler))
  }

  /// Deliver each frame for a name to a receiver, which answers with reply.
  @discardableResult
  public func registerReceiver(_ name: String, _ receiver: @escaping @Sendable (Frame) -> Void)
    throws -> String
  {
    try register(name, .receiver(receiver))
  }

  /// A service the node closes when it closes.
  public func adopt(_ service: any NodeService) { state.with { $0.services.append(service) } }

  /// Remove a name; requests to it still waiting are answered as stopped.
  public func unregister(_ name: String) {
    let waiting: [SeenKey] = state.with { s in
      guard s.entities.removeValue(forKey: name) != nil else { return [] }
      return s.seen.filter { $0.value.entity == name && $0.value.response == nil }.map(\.key)
    }
    for key in waiting { answer(key, 2, Array("the receiving entity has stopped".utf8)) }
  }

  /// Send a frame of a kind to an address, with no reply.
  public func send(_ address: String, _ kind: String, _ payload: [UInt8]) throws {
    let frame = Wire.frameTo(address, kind, payload)
    try validate(frame)
    try transmit(frame)
  }

  /// Send a frame as given (an endpoint's protocol frames).
  public func forward(_ frame: Frame) throws {
    try validate(frame)
    try transmit(frame)
  }

  /// Request: retried every 100 ms until a reply or the timeout (ms). The
  /// callback gets the reply's status and body, or the failure. Returns
  /// the request's identity.
  @discardableResult
  public func requestAsync(
    _ address: String, _ kind: String, _ payload: [UInt8], _ timeout: Int,
    _ respond: @escaping @Sendable (Reply) -> Void
  ) throws -> UInt64 {
    if timeout < 0 { throw Node.fail("invalid_timeout") }
    let (peer, _) = try Wire.splitAddress(address)
    let (identity, frame): (UInt64, Frame) = try state.with { s in
      if s.closed { throw Node.fail("node_closed") }
      let identity = s.nextId
      s.nextId += 1
      let frame = Frame(kind: kind, to: address, source: "", id: identity, payload: payload)
      try validate(frame)
      let p = Pending(
        peer: peer, deadline: Date().addingTimeInterval(Double(timeout) / 1000), respond: respond)
      s.pending[identity] = p
      let period = max(1, min(100, timeout))
      p.timer = NetworkTimer(period) { [weak self] in
        guard let self else { return }
        let resend: Bool? = self.state.with { s in
          guard let q = s.pending[identity] else { return nil }
          return Date() < q.deadline
        }
        switch resend {
        case .some(true): _ = try? self.transmit(frame)
        case .some(false): self.finish(identity, .failure(NodeFailure("unreachable " + address)))
        case .none: return
        }
      }
      return (identity, frame)
    }
    try transmit(frame)
    return identity
  }

  /// Request and wait for the reply's status and body.
  public func request(_ address: String, _ kind: String, _ payload: [UInt8], _ timeout: Int) throws
    -> (Int, [UInt8])
  {
    let result = Locked<Reply?>(nil)
    let done = DispatchSemaphore(value: 0)
    try requestAsync(address, kind, payload, timeout) { reply in
      result.with { $0 = reply }
      done.signal()
    }
    done.wait()
    switch result.with({ $0 })! {
    case .success(let reply): return reply
    case .failure(let failure): throw Node.fail(failure.reason)
    }
  }

  /// Forget a request; its callback is not called.
  public func cancel(_ identity: UInt64) { finish(identity, nil) }

  /// Answer a request a receiver was given.
  public func reply(_ source: String, _ identity: UInt64, _ status: Int, _ body: [UInt8]) throws {
    if status < 0 || status > 255 { throw Node.fail("invalid_reply") }
    if identity != 0 { answer(SeenKey(source: source, id: identity), status, body) }
  }

  /// Close the node: its services, its waiting requests and its transport.
  public func close() {
    let (waiting, services): ([Pending], [any NodeService]) = state.with { s in
      if s.closed { return ([], []) }
      s.closed = true
      let all = Array(s.pending.values)
      s.pending.removeAll()
      let services = s.services
      s.services.removeAll()
      return (all, services)
    }
    for service in services { service.release() }
    for p in waiting {
      p.timer?.cancel()
      p.respond(.failure(NodeFailure("node_closed")))
    }
    let deadline = Date().addingTimeInterval(5)
    while state.with({ $0.jobs }) > 0 && Date() < deadline { usleep(2000) }
    if let secure { secure.close() } else { raw?.close() }
  }
}
