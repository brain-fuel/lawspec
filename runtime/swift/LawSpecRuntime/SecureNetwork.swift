// One owned security layer per node: signed ML-KEM handshakes, address-pinned
// ML-DSA identities, and authenticated encrypted frames. Frames reach the
// node only after they open under a session's key.
// ref:DEC-distribution-canonical-wire

import Foundation

/// A node's identity and the fingerprints it trusts (nil: trust on first use).
public struct NetworkOptions: Sendable {
    public var identity: NodeIdentity?
    public var identitySeed: [UInt8]?
    public var trusted: [String]?
    /// Whether trusted was given (so the configuration file is not read for it).
    public var trustGiven: Bool
    public var firstId: UInt64?

    public init(identity: NodeIdentity? = nil, identitySeed: [UInt8]? = nil, trusted: [String]? = nil, trustGiven: Bool = false, firstId: UInt64? = nil) {
        self.identity = identity
        self.identitySeed = identitySeed
        self.trusted = trusted
        self.trustGiven = trustGiven
        self.firstId = firstId
    }
}

/// Node identities and trust from options, then lawspec-network.conf (found
/// from the working directory up, or named by LAWSPEC_NETWORK_CONF), whose
/// `identity` line names a file of the seed in hexadecimal and whose
/// `trusted` line names a file of fingerprints.
public enum NetworkConfig {
    public static let empty = NetworkOptions()

    private static func locate() -> String? {
        if let file = ProcessInfo.processInfo.environment["LAWSPEC_NETWORK_CONF"], !file.isEmpty {
            return URL(fileURLWithPath: file).standardizedFileURL.path
        }
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        while true {
            let path = directory.appendingPathComponent("lawspec-network.conf").path
            if FileManager.default.fileExists(atPath: path) { return path }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    public static func configured() throws -> ([UInt8]?, [String]?) {
        guard let path = locate(), FileManager.default.fileExists(atPath: path) else { return (nil, nil) }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        var identity: [UInt8]? = nil
        var trusted: [String]? = nil
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            for kind in ["identity", "trusted"] {
                guard trimmed.hasPrefix(kind), trimmed.count > kind.count,
                      trimmed[trimmed.index(trimmed.startIndex, offsetBy: kind.count)].isWhitespace else { continue }
                let name = String(trimmed.dropFirst(kind.count)).trimmingCharacters(in: .whitespaces)
                let content = try String(contentsOfFile: directory.appendingPathComponent(name).path, encoding: .utf8)
                if kind == "identity" {
                    guard let seed = Wire.unhex(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw Fail.with("InvalidNodeIdentity")
                    }
                    identity = seed
                } else {
                    trusted = content.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                }
            }
        }
        return (identity, trusted)
    }

    public static func fingerprint(_ value: String) throws -> String {
        try Fail.require(value.utf8.count == 64 && Wire.unhex(value) != nil, "InvalidTrustedFingerprint")
        return value.lowercased()
    }

    /// The identity and the trusted set to use.
    public static func resolve(_ options: NetworkOptions) throws -> (NodeIdentity, Set<String>?) {
        let (fileIdentity, fileTrusted) =
            (options.identity != nil || options.identitySeed != nil) && options.trustGiven ? (nil, nil) : try configured()
        let identity: NodeIdentity
        if let given = options.identity {
            identity = given
        } else if let seed = options.identitySeed ?? fileIdentity {
            identity = try NetworkRecords.identity(seed)
        } else {
            identity = try NetworkRecords.identity(CryptoPrimitives.randomBytes(32))
        }
        let trusted = options.trustGiven ? options.trusted : fileTrusted
        return (identity, try trusted.map { Set(try $0.map(fingerprint)) })
    }
}

final class SecureLayer: @unchecked Sendable {
    private final class Pending {
        let session: [UInt8]
        let seed: [UInt8]
        let body: [UInt8]
        let hello: [UInt8]
        var queue: [[UInt8]]
        var timer: NetworkTimer?

        init(session: [UInt8], seed: [UInt8], body: [UInt8], hello: [UInt8], queue: [[UInt8]]) {
            self.session = session
            self.seed = seed
            self.body = body
            self.hello = hello
            self.queue = queue
        }
    }

    private struct State {
        var known: [String: String] = [:]
        var sessions: [[UInt8]: (String, [UInt8], Int)] = [:]
        var outbound: [String: [UInt8]] = [:]
        var pending: [String: Pending] = [:]
        var welcomes: [[UInt8]: ([UInt8], [UInt8], String)] = [:]
        var closed = false
    }

    private let identity: NodeIdentity
    private let trusted: Set<String>?
    private let deliver: PacketReceiver
    private let state = Locked(State())
    private var connection: (any PacketTransport)!

    init(_ transport: Transport, _ options: NetworkOptions, _ deliver: @escaping PacketReceiver) throws {
        (identity, trusted) = try NetworkConfig.resolve(options)
        self.deliver = deliver
        connection = try Transports.open(transport) { [weak self] _, bytes in
            guard let self else { return }
            try? self.incoming(bytes)
        }
    }

    var address: String { connection.address }

    /// The SHA3-256 fingerprint of this node's public key.
    var fingerprint: String { NetworkRecords.fingerprint(identity) }

    private func accept(_ peer: String, _ publicKey: [UInt8], _ s: inout State) throws {
        let fingerprint = Wire.hex(CryptoPrimitives.sha3(publicKey))
        if let set = trusted, !set.contains(fingerprint) { throw Fail.with("UntrustedPeer", peer) }
        if let existing = s.known[peer], existing != fingerprint { throw Fail.with("PeerIdentityChanged", peer) }
        s.known[peer] = fingerprint
    }

    private func validPeer(_ peer: String) throws {
        let (node, name) = try Wire.splitAddress(peer + "/")
        if node != peer || !name.isEmpty { throw Fail.with("InvalidPeer", peer) }
    }

    private func signed(_ kind: UInt8, _ prefix: String, _ body: [UInt8]) throws -> [UInt8] {
        NetworkRecords.record(kind, body, try NetworkRecords.sign(identity.seed, Array(prefix.utf8) + body))
    }

    private func wire(_ peer: String, _ bytes: [UInt8]) -> String? { connection.send(peer, bytes) }

    private func incoming(_ record: [UInt8]) throws {
        var outgoing = [(String, [UInt8])]()
        var received = [(String, [UInt8])]()
        try state.with { s in
            switch try NetworkRecords.read(record) {
            case .handshake(1, let values, let body, let signature) where values.count == 4:
                let (session, peerBytes, publicKey, kem) = (values[0], values[1], values[2], values[3])
                if session.count != 16 || kem.count != 1184 { throw Fail.with("InvalidHello") }
                let peer = String(decoding: peerBytes, as: UTF8.self)
                try validPeer(peer)
                if let (hello, answer, from) = s.welcomes[session] {
                    if from == peer && hello == record { outgoing.append((peer, answer)) }
                    return
                }
                if s.sessions[session] != nil || s.pending.values.contains(where: { $0.session == session }) {
                    throw Fail.with("DuplicateSession")
                }
                if !CryptoPrimitives.mldsaVerify(publicKey, Array("lawspec-handshake-v1-hello".utf8) + body, signature) {
                    throw Fail.with("BadSignature")
                }
                try accept(peer, publicKey, &s)
                let (ciphertext, shared) = try NetworkRecords.encapsulate(kem)
                let welcomeBody = NetworkRecords.welcome(session, connection.address, identity.publicKey, ciphertext, body)
                let answer = try signed(2, "lawspec-handshake-v1-welcome", welcomeBody)
                let sessionKey = NetworkRecords.key(shared, body, welcomeBody)
                s.welcomes[session] = (record, answer, peer)
                s.sessions[session] = (peer, sessionKey, 1)
                outgoing.append((peer, answer))
            case .handshake(2, let values, let body, let signature) where values.count == 5:
                let (session, peerBytes, publicKey, ciphertext, hash) = (values[0], values[1], values[2], values[3], values[4])
                let peer = String(decoding: peerBytes, as: UTF8.self)
                guard let p = s.pending[peer], p.session == session else { return }
                if ciphertext.count != 1088 || hash != CryptoPrimitives.sha3(p.body) { throw Fail.with("InvalidWelcome") }
                if !CryptoPrimitives.mldsaVerify(publicKey, Array("lawspec-handshake-v1-welcome".utf8) + body, signature) {
                    throw Fail.with("BadSignature")
                }
                try accept(peer, publicKey, &s)
                let sessionKey = NetworkRecords.key(try NetworkRecords.decapsulate(p.seed, ciphertext), p.body, body)
                p.timer?.cancel()
                s.pending[peer] = nil
                s.sessions[session] = (peer, sessionKey, 0)
                s.outbound[peer] = session
                for frame in p.queue { outgoing.append((peer, try NetworkRecords.seal(sessionKey, session, 0, frame))) }
            case .sealed(let session, let direction, let sealedBytes):
                guard let (peer, sessionKey, own) = s.sessions[session], direction == 1 - own else { return }
                if let frame = NetworkRecords.openSealed(sessionKey, session, direction, sealedBytes) {
                    received.append((peer, frame))
                    if s.outbound[peer] == nil { s.outbound[peer] = session }
                }
            default:
                return
            }
        }
        for (peer, bytes) in outgoing { _ = wire(peer, bytes) }
        for (peer, frame) in received { deliver(peer, frame) }
    }

    private enum Action {
        case send([UInt8])
        case done(String?)
    }

    /// Seal a frame for a peer, after a handshake if there is no session yet.
    /// Nil, or why it failed.
    func send(_ peer: String, _ frame: [UInt8]) -> String? {
        let action: Action
        do {
            action = try state.with { s throws -> Action in
                if s.closed { return .done("transport_closed") }
                if let session = s.outbound[peer], let (_, sessionKey, direction) = s.sessions[session] {
                    return .send(try NetworkRecords.seal(sessionKey, session, direction, frame))
                }
                if let p = s.pending[peer] {
                    if p.queue.count < 4096 {
                        p.queue.append(frame)
                        return .done(nil)
                    }
                    return .done("handshake_queue_full")
                }
                let session = CryptoPrimitives.randomBytes(16)
                let (kem, seed) = CryptoPrimitives.mlkemKeyPair(CryptoPrimitives.randomBytes(64))
                let body = NetworkRecords.hello(session, connection.address, identity.publicKey, kem)
                let hello = try signed(1, "lawspec-handshake-v1-hello", body)
                let deadline = Date().addingTimeInterval(5)
                let p = Pending(session: session, seed: seed, body: body, hello: hello, queue: [frame])
                s.pending[peer] = p
                let handle = UncheckedBox(p)
                p.timer = NetworkTimer(100) { [weak self] in
                    guard let self else { return }
                    let resend: Bool = self.state.with { s in
                        guard let q = s.pending[peer], q === handle.value else { return false }
                        if Date() >= deadline {
                            q.timer?.cancel()
                            s.pending[peer] = nil
                            return false
                        }
                        return true
                    }
                    if resend { _ = self.wire(peer, hello) }
                }
                return .send(hello)
            }
        } catch {
            return "secure_layer_failed"
        }
        switch action {
        case .send(let bytes): return wire(peer, bytes)
        case .done(let result): return result
        }
    }

    func close() {
        state.with { s in
            s.closed = true
            for p in s.pending.values { p.timer?.cancel() }
            s.pending.removeAll()
        }
        connection.close()
    }
}
