// The distribution frame format every target shares: kind, destination,
// source, request identity and payload, each in the canonical descriptor
// encoding, so a node on one target talks to a node on another. A received
// frame never names anything it did not carry.
// ref:DEC-distribution-canonical-wire

import Foundation

/// A frame: its kind ("call", "chan", "reply", ...), the entity it is for
/// (on send, a full address; on the wire, the name at the peer), the source
/// node's address, the request identity (0 for none) and the payload.
public struct Frame: Sendable, Equatable {
    public var kind: String
    public var to: String
    public var source: String
    public var id: UInt64
    public var payload: [UInt8]

    public init(kind: String, to: String, source: String, id: UInt64, payload: [UInt8]) {
        self.kind = kind
        self.to = to
        self.source = source
        self.id = id
        self.payload = payload
    }
}

public enum Wire {
    public typealias Descriptor = Descriptors.Descriptor

    private static func atom(_ name: String) -> Descriptor { .forms([.atom(name)]) }
    static let textType = atom("text")
    static let bytesType = atom("bytes")
    static let identityType: Descriptor = .forms([.atom("int"), .atom("UInt64"), .number(.zero), .number(BigInt(UInt64.max))])
    static let sequenceType: Descriptor = .forms([.atom("int"), .atom("Int64"), .number(BigInt(Int64.min)), .number(BigInt(Int64.max))])

    /// A frame to send: the source and identity are filled in by the node.
    public static func frameTo(_ address: String, _ kind: String, _ payload: [UInt8]) -> Frame {
        Frame(kind: kind, to: address, source: "", id: 0, payload: payload)
    }

    /// The concatenated canonical encodings of values at their descriptors.
    public static func fields(_ types: [Descriptor], _ values: [Value]) throws -> [UInt8] {
        try Fail.require(types.count == values.count, "WireFieldCount")
        var out = [UInt8]()
        for (d, v) in zip(types, values) { out += try Descriptors.encode(d, v, [:]) }
        return out
    }

    /// Values read in turn from a position, and the position after them.
    public static func readFields(_ types: [Descriptor], _ bytes: [UInt8], _ start: Int) throws -> ([Value], Int) {
        var position = start
        var values = [Value]()
        for d in types {
            let (v, next) = try Descriptors.decodePrefix(d, bytes, position, [:])
            values.append(v)
            position = next
        }
        return (values, position)
    }

    static func text(_ v: Value) throws -> String {
        guard case .text(let s) = v else { throw Fail.with("InvalidFrame") }
        return s
    }

    static func bytesOf(_ v: Value) throws -> [UInt8] {
        guard case .bytes(let b) = v else { throw Fail.with("InvalidFrame") }
        return b
    }

    /// A frame's bytes.
    public static func encode(_ kind: String, _ to: String, _ source: String, _ identity: UInt64, _ payload: [UInt8]) throws -> [UInt8] {
        try fields([textType, textType, textType, identityType, bytesType],
                   [.text(kind), .text(to), .text(source), .int(BigInt(identity)), .bytes(payload)])
    }

    /// A frame from exactly its bytes, or nil when they are not one.
    public static func read(_ bytes: [UInt8]) -> Frame? {
        guard let (values, next) = try? readFields([textType, textType, textType, identityType, bytesType], bytes, 0),
              next == bytes.count, values.count == 5,
              case .text(let kind) = values[0], case .text(let to) = values[1], case .text(let source) = values[2],
              case .int(let identity) = values[3], let id = identity.exactly(UInt64.self),
              case .bytes(let payload) = values[4] else { return nil }
        return Frame(kind: kind, to: to, source: source, id: id, payload: payload)
    }

    /// A channel payload: sequence number, sender address, body.
    public static func channel(_ sequence: Int64, _ sender: String, _ body: [UInt8]) throws -> [UInt8] {
        try fields([sequenceType, textType], [.int(BigInt(sequence)), .text(sender)]) + body
    }

    public static func readChannel(_ bytes: [UInt8]) throws -> (Int64, String, [UInt8]) {
        let (values, next) = try readFields([sequenceType, textType], bytes, 0)
        guard case .int(let sequence) = values[0], let n = sequence.exactly(Int64.self), case .text(let sender) = values[1] else {
            throw Fail.with("InvalidChannelPayload")
        }
        return (n, sender, Array(bytes[next...]))
    }

    public static func sequence(_ n: Int64) throws -> [UInt8] { try Descriptors.encode(sequenceType, .int(BigInt(n)), [:]) }

    public static func readSequence(_ bytes: [UInt8]) throws -> Int64 {
        guard case .int(let n) = try Descriptors.decode(sequenceType, bytes, [:]), let v = n.exactly(Int64.self) else {
            throw Fail.with("InvalidSequence")
        }
        return v
    }

    /// An address's node and entity name: tcp://host:port/name gives
    /// (tcp://host:port, name). The node part must have a scheme.
    public static func splitAddress(_ address: String) throws -> (String, String) {
        guard let at = address.lastIndex(of: "/") else { throw Fail.with("InvalidAddress", address) }
        let node = String(address[..<at])
        guard node.contains("://") else { throw Fail.with("InvalidAddress", address) }
        return (node, String(address[address.index(after: at)...]))
    }

    /// Text fields of a payload, as the channel protocol's control frames carry them.
    static func texts(_ values: [String]) throws -> [UInt8] {
        try fields(values.map { _ in textType }, values.map { .text($0) })
    }

    static func readTexts(_ count: Int, _ bytes: [UInt8], _ start: Int) throws -> ([String], Int) {
        let (values, next) = try readFields(Array(repeating: textType, count: count), bytes, start)
        return (try values.map(text), next)
    }

    /// A list of texts and the position after it.
    static func readTextList(_ bytes: [UInt8], _ start: Int) throws -> ([String], Int) {
        let (n, position) = try Descriptors.readVarint(bytes, start)
        guard let count = n.exactly(Int.self), count >= 0 else { throw Fail.with("InvalidFrame") }
        var at = position
        var items = [String]()
        for _ in 0..<count {
            let (v, next) = try Descriptors.decodePrefix(textType, bytes, at, [:])
            items.append(try text(v))
            at = next
        }
        return (items, at)
    }

    static func textList(_ items: [String]) throws -> [UInt8] {
        try Descriptors.encode(.forms([.atom("list"), textType]), .list(items.map { .text($0) }), [:])
    }

    /// A list of byte strings, encoded and read.
    static func bytesList(_ items: [[UInt8]]) throws -> [UInt8] {
        try Descriptors.encode(.forms([.atom("list"), bytesType]), .list(items.map { .bytes($0) }), [:])
    }

    static func readBytesList(_ bytes: [UInt8], _ start: Int) throws -> ([[UInt8]], Int) {
        let (n, position) = try Descriptors.readVarint(bytes, start)
        guard let count = n.exactly(Int.self), count >= 0 else { throw Fail.with("InvalidFrame") }
        var at = position
        var items = [[UInt8]]()
        for _ in 0..<count {
            let (v, next) = try Descriptors.decodePrefix(bytesType, bytes, at, [:])
            items.append(try bytesOf(v))
            at = next
        }
        return (items, at)
    }

    /// Lowercase hexadecimal of bytes.
    public static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 15)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The bytes of hexadecimal text, or nil.
    public static func unhex(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func digit(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = digit(chars[i]), let lo = digit(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    /// The UTF-8 bytes of text.
    static func utf8(_ text: String) -> [UInt8] { Array(text.utf8) }
}

/// A repeating timer on a background queue, cancelled once.
final class NetworkTimer: @unchecked Sendable {
    private let source: DispatchSourceTimer

    /// Call a body every period (milliseconds), first after one period.
    init(_ period: Int, _ body: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeTimerSource(queue: .global())
        source.schedule(deadline: .now() + .milliseconds(period), repeating: .milliseconds(period))
        source.setEventHandler(handler: body)
        source.resume()
    }

    func cancel() { source.cancel() }

    /// Run a body once after a delay (milliseconds).
    static func after(_ delay: Int, _ body: @escaping @Sendable () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delay), execute: body)
    }
}
