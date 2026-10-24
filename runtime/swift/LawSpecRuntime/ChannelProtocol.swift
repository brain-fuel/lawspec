// Pure transitions of a reliable, movable network channel end. Its owner
// keeps the timers and sends the frames each transition returns.
// Application values enter as canonical bytes and leave in send order,
// exactly once; an end that has not been used can move to another node with
// its state, and its peer follows it. Times are monotonic microseconds.
// ref:DEC-distribution-canonical-wire ref:DEC-sessions-by-construction

public enum ChannelProtocol {
  static let retry: Int64 = 50000

  public struct Unacked: Sendable {
    var body: [UInt8]
    var first: Int64
    var last: Int64
  }

  public struct Taking: Sendable {
    var from: String
    var token: String
    var first: Int64
    var last: Int64
  }

  public struct State: Sendable {
    public var address: String
    var deadline: Int64
    public var peer: String?
    var out: Int64 = 0
    var expected: Int64 = 0
    var unacked: [Int64: Unacked] = [:]
    var early: [Int64: [UInt8]] = [:]
    var received: [[UInt8]] = []
    public var failure: String?
    public var closed = false
    public var eof = false
    public var used = false
    var history: [String] = []
    var token: String?
    public var moved: String?
    var snapshot: [UInt8]?
    var taking: Taking?
    var taken = false
    var confirmed = false
    var announcing = false
    var announcedAt: Int64?

    init(address: String, deadline: Int64) {
      self.address = address
      self.deadline = deadline
    }
  }

  /// What a reader gets.
  public enum Received: Sendable {
    case empty
    case body([UInt8])
    case failed(String)
  }

  public static let eofReason = "the other end gave up the conversation"
  public static let takeFailure =
    "the node the end came from did not hand it over in time (unreachable)"
  static let hello = Array("hello".utf8)

  private static func unavailable() -> LawSpecError { Fail.with("ChannelEndUnavailable") }

  private static func check(_ condition: Bool) throws {
    if !condition { throw Fail.with("InvalidChannelOperation") }
  }

  /// A new end at an address; the deadline is in microseconds.
  public static func create(_ address: String, _ deadline: Int64) throws -> State {
    _ = try Wire.splitAddress(address)
    try check(deadline > 0)
    return State(address: address, deadline: deadline)
  }

  private static func message(_ destination: String, _ kind: String, _ payload: [UInt8]) -> Frame {
    Wire.frameTo(destination, kind, payload)
  }

  private static func usable(_ state: State) throws {
    if state.eof { throw unavailable() }
    let fresh = state.failure == nil && !state.closed && state.token == nil && state.moved == nil
    if !(fresh && (state.taking == nil || state.taken)) { throw unavailable() }
  }

  private static func channelFrame(_ state: State, _ sequence: Int64, _ body: [UInt8]) throws
    -> Frame
  {
    message(state.peer!, "chan", try Wire.channel(sequence, state.address, body))
  }

  private static func transmit(_ state: State, _ sequence: Int64, _ body: [UInt8], _ now: Int64)
    throws -> (State, [Frame])
  {
    _ = try Wire.channel(sequence, state.address, body)
    var next = state
    next.unacked[sequence] = Unacked(body: body, first: now, last: now)
    return (next, state.peer == nil ? [] : [try channelFrame(state, sequence, body)])
  }

  /// Greet a peer end.
  public static func connect(_ state: State, _ peer: String, _ now: Int64) throws -> (
    State, [Frame]
  ) {
    try usable(state)
    try check(state.peer == nil)
    _ = try Wire.splitAddress(peer)
    var s = state
    s.peer = peer
    return try transmit(s, -1, hello, now)
  }

  /// Send a value's bytes.
  public static func send(_ state: State, _ bytes: [UInt8], _ now: Int64) throws -> (State, [Frame])
  {
    try usable(state)
    var s = state
    s.out += 1
    s.used = true
    return try transmit(s, state.out, [0] + bytes, now)
  }

  /// Give up the conversation: an ordered end-of-file frame.
  public static func abandon(_ state: State, _ now: Int64) throws -> (State, [Frame]) {
    if state.closed || state.moved != nil { return (state, []) }
    var s = state
    s.closed = true
    if state.failure != nil { return (s, []) }
    s.out += 1
    return try transmit(s, state.out, [1], now)
  }

  /// The next value for a reader, if there is one.
  public static func receiveBody(_ state: State) -> (Received, State) {
    if state.token != nil || state.moved != nil {
      return (.failed("the channel end has been offered or moved"), state)
    }
    var s = state
    if let body = state.received.first {
      if body.count >= 1 && body[0] == 0 {
        s.received.removeFirst()
        s.used = true
        return (.body(Array(body.dropFirst())), s)
      }
      s.received = []
      s.used = true
      s.eof = true
      return (.failed(eofReason), s)
    }
    if state.eof { return (.failed(eofReason), state) }
    if let reason = state.failure { return (.failed(reason), state) }
    return (.empty, state)
  }

  private static func validBody(_ body: [UInt8]) -> Bool {
    (body.count >= 1 && body[0] == 0) || body == [1]
  }

  private static func drain(_ state: State) -> State {
    var s = state
    while let body = s.early.removeValue(forKey: s.expected) {
      s.expected += 1
      s.received.append(body)
    }
    return s
  }

  private static func fail(_ reason: String, _ state: State) -> State {
    if state.failure != nil { return state }
    var s = state
    s.failure = reason
    s.unacked = [:]
    return s
  }

  private static func numbered(_ entries: [(Int64, [UInt8])]) throws -> [UInt8] {
    var out = try Descriptors.varint(BigInt(entries.count))
    for (n, body) in entries {
      out += try Wire.fields([Wire.sequenceType, Wire.bytesType], [.int(BigInt(n)), .bytes(body)])
    }
    return out
  }

  private static func readNumbered(_ bytes: [UInt8], _ start: Int) throws -> (
    [(Int64, [UInt8])], Int
  ) {
    let (count, position) = try Descriptors.readVarint(bytes, start)
    try check(count <= BigInt((bytes.count - position) / 2))
    var at = position
    var entries = [(Int64, [UInt8])]()
    for _ in 0..<(count.exactly(Int.self) ?? 0) {
      let (values, next) = try Wire.readFields([Wire.sequenceType, Wire.bytesType], bytes, at)
      guard case .int(let n) = values[0], let v = n.exactly(Int64.self),
        case .bytes(let body) = values[1]
      else {
        throw Fail.with("InvalidSnapshot")
      }
      entries.append((v, body))
      at = next
    }
    return (entries, at)
  }

  private static func snapshot(_ state: State) throws -> [UInt8] {
    let prefix = try Wire.fields(
      [
        Wire.textType, Wire.textType, Wire.textType, .forms([.atom("list"), Wire.textType]),
        Wire.sequenceType, Wire.sequenceType,
      ],
      [
        .text(state.token ?? ""), .text(state.failure ?? ""), .text(state.peer ?? ""),
        .list((state.history + [state.address]).map { .text($0) }), .int(BigInt(state.out)),
        .int(BigInt(state.expected)),
      ])
    let unacked = state.unacked.keys.sorted().map { ($0, state.unacked[$0]!.body) }
    let early = state.early.keys.sorted().map { ($0, state.early[$0]!) }
    return prefix + (try numbered(unacked)) + (try numbered(early))
      + (try Wire.bytesList(state.received))
  }

  private static func tickTaking(_ state: State, _ taking: Taking, _ now: Int64) throws -> (
    State, [Frame]
  ) {
    if now - taking.first >= state.deadline { return (fail(takeFailure, state), []) }
    if now - taking.last > retry {
      var s = state
      var t = taking
      t.last = now
      s.taking = t
      return (s, [message(taking.from, "take", try Wire.texts([taking.token, state.address]))])
    }
    return (state, [])
  }

  private static func announce(_ state: State, _ now: Int64) throws -> (State, [Frame]) {
    guard state.announcing, !state.confirmed else { return (state, []) }
    if let at = state.announcedAt, now - at <= retry { return (state, []) }
    var s = state
    s.announcedAt = now
    return (
      s,
      [
        message(
          state.peer!, "moved", try Wire.textList(state.history) + (try Wire.texts([state.address]))
        )
      ]
    )
  }

  /// Retransmit what is due, fail what is overdue, and keep a take going.
  public static func tick(_ state: State, _ now: Int64) throws -> (State, [Frame]) {
    if state.moved != nil || state.failure != nil { return (state, []) }
    if let taking = state.taking, !state.taken { return try tickTaking(state, taking, now) }
    let due = state.unacked.keys.sorted().compactMap { n in
      state.unacked[n].flatMap { now - $0.last > retry ? (n, $0) : nil }
    }
    if due.contains(where: { now - $0.1.first > state.deadline }) {
      return (fail("the other end did not answer in time (unreachable)", state), [])
    }
    if state.peer == nil { return (state, []) }
    var (s1, announced) = try announce(state, now)
    var frames = [Frame]()
    for (n, e) in due {
      frames.append(try channelFrame(s1, n, e.body))
      s1.unacked[n]?.last = now
    }
    return (s1, announced + frames)
  }

  private static func give(_ state: State, _ payload: [UInt8]) throws -> (State, [Frame]) {
    let (values, next) = try Wire.readTexts(2, payload, 0)
    guard next == payload.count else { return (state, []) }
    let (token, taker) = (values[0], values[1])
    _ = try Wire.splitAddress(taker)
    if state.token != token { return (state, []) }
    if let moved = state.moved {
      return moved == taker ? (state, [message(taker, "state", state.snapshot!)]) : (state, [])
    }
    let snap = try snapshot(state)
    var s = state
    s.moved = taker
    s.snapshot = snap
    s.unacked = [:]
    s.early = [:]
    return (s, [message(taker, "state", snap)])
  }

  private static func install(_ state: State, _ payload: [UInt8], _ now: Int64) throws -> (
    State, [Frame]
  ) {
    let taking = state.taking!
    let (values, r1) = try Wire.readTexts(3, payload, 0)
    let (token, failure, peer) = (values[0], values[1], values[2])
    guard token == taking.token else { return (state, []) }
    let (history, r2) = try Wire.readTextList(payload, r1)
    try check(!history.isEmpty && history.last == taking.from)
    for h in history { _ = try Wire.splitAddress(h) }
    if !peer.isEmpty { _ = try Wire.splitAddress(peer) }
    let (outExpected, r3) = try Wire.readFields(
      [Wire.sequenceType, Wire.sequenceType], payload, r2)
    guard case .int(let o) = outExpected[0], case .int(let e) = outExpected[1],
      let out = o.exactly(Int64.self), let expected = e.exactly(Int64.self)
    else { throw Fail.with("InvalidSnapshot") }
    try check(out >= 0 && expected >= 0)
    let (unacked, r4) = try readNumbered(payload, r3)
    let (early, r5) = try readNumbered(payload, r4)
    let (received, r6) = try Wire.readBytesList(payload, r5)
    try check(r6 == payload.count)
    try check(received.allSatisfy(validBody))
    try check(early.allSatisfy { $0.0 >= expected && validBody($0.1) })
    try check(
      unacked.allSatisfy {
        ($0.0 == -1 && $0.1 == hello) || ($0.0 >= 0 && $0.0 < out && validBody($0.1))
      })
    try check(Set(unacked.map(\.0)).count == unacked.count)
    try check(Set(early.map(\.0)).count == early.count)
    var s1 = state
    s1.peer = peer.isEmpty ? nil : peer
    s1.history = history
    s1.out = out
    s1.expected = expected
    s1.unacked = Dictionary(
      uniqueKeysWithValues: unacked.map {
        ($0.0, Unacked(body: $0.1, first: now, last: now - retry - 1))
      })
    s1.early = Dictionary(uniqueKeysWithValues: early)
    s1.received = received
    s1.announcing = true
    s1.announcedAt = nil
    s1.taken = true
    return failure.isEmpty ? try tick(drain(s1), now) : (fail(failure, s1), [])
  }

  private static func peerMoved(_ state: State, _ payload: [UInt8]) throws -> (State, [Frame]) {
    let (history, rest) = try Wire.readTextList(payload, 0)
    let (values, next) = try Wire.readTexts(1, payload, rest)
    guard next == payload.count else { return (state, []) }
    let destination = values[0]
    _ = try Wire.splitAddress(destination)
    var s1 = state
    if let p = state.peer {
      if history.contains(p) { s1.peer = destination }
    } else {
      s1.peer = destination
    }
    if s1.peer == destination {
      return (
        s1,
        [
          message(
            destination, "moved-ack", try Descriptors.encode(Wire.textType, .text(destination), [:])
          )
        ]
      )
    }
    return (s1, [])
  }

  private static func arriving(_ state: State, _ frame: Frame, _ now: Int64) throws -> (
    State, [Frame]
  ) {
    if frame.kind == "take" { return try give(state, frame.payload) }
    if let moved = state.moved {
      var f = frame
      f.to = moved
      return (state, [f])
    }
    if state.taking != nil && !state.taken {
      return frame.kind == "state" ? try install(state, frame.payload, now) : (state, [])
    }
    switch frame.kind {
    case "chan" where state.failure != nil:
      return (state, [])
    case "ack":
      var s = state
      s.unacked[try Wire.readSequence(frame.payload)] = nil
      return (s, [])
    case "moved":
      return try peerMoved(state, frame.payload)
    case "moved-ack":
      let (values, next) = try Wire.readTexts(1, frame.payload, 0)
      if next == frame.payload.count && values[0] == state.address {
        var s = state
        s.confirmed = true
        return (s, [])
      }
      return (state, [])
    case "chan":
      let (sequence, sender, body) = try Wire.readChannel(frame.payload)
      _ = try Wire.splitAddress(sender)
      var updated = state
      if sequence == -1 {
        try check(body == hello)
        if state.peer == nil { updated.peer = sender }
      } else {
        try check(sequence >= 0 && validBody(body))
        try check(!state.eof || sequence < state.expected)
        if sequence >= state.expected && state.early[sequence] == nil {
          updated.early[sequence] = body
          updated = drain(updated)
        }
      }
      return (updated, [message(sender, "ack", try Wire.sequence(sequence))])
    default:
      return (state, [])
    }
  }

  /// A frame for this end. Invalid frames change nothing.
  public static func accept(_ state: State, _ frame: Frame, _ now: Int64) -> (State, [Frame]) {
    (try? arriving(state, frame, now)) ?? (state, [])
  }

  /// Offer an unused end to another node: the address that takes it.
  public static func offer(_ state: State, _ token: String) throws -> (String, State) {
    try check(
      !token.isEmpty && !state.used && !state.closed && state.moved == nil
        && (state.taking == nil || state.taken))
    let chosen = state.token ?? token
    var s = state
    s.token = chosen
    return (state.address + "?take=" + chosen, s)
  }

  /// Take an offered end, by the address its offer gave.
  public static func take(_ state: State, _ address: String, _ now: Int64) throws -> (
    State, [Frame]
  ) {
    try usable(state)
    try check(!state.used)
    guard let range = address.range(of: "?take=") else {
      throw Fail.with("InvalidChannelOperation")
    }
    let old = String(address[..<range.lowerBound])
    let token = String(address[range.upperBound...])
    try check(!token.isEmpty)
    _ = try Wire.splitAddress(old)
    var s = state
    s.taking = Taking(from: old, token: token, first: now, last: now - retry - 1)
    return try tick(s, now)
  }

  /// Whether a take has finished: true or false, or the failure.
  public static func takeStatus(_ state: State, _ now: Int64) -> Result<Bool, NodeFailure> {
    guard let taking = state.taking else { return .success(true) }
    if state.taken {
      return .success(
        state.confirmed || state.failure != nil || now - taking.first >= state.deadline)
    }
    if state.failure != nil || now - taking.first >= state.deadline {
      return .failure(NodeFailure(takeFailure))
    }
    return .success(false)
  }
}
