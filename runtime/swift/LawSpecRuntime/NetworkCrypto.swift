// The secure transport's version 1 records ("LS" 1): a node's ML-DSA-65
// identity, the signed hello and welcome of the ML-KEM-768 handshake, the
// session key derived with SHAKE256, and AES-256-GCM sealed frames. Every
// target writes the same bytes for the same seeds, so nodes interoperate.
// ref:DEC-distribution-canonical-wire

/// A node's identity: its ML-DSA-65 seed and public key.
public struct NodeIdentity: Sendable {
    public let seed: [UInt8]
    public let publicKey: [UInt8]
}

public enum NetworkRecords {
    private static let bytesType = Wire.bytesType

    public static func fields(_ values: [[UInt8]]) -> [UInt8] {
        var out = [UInt8]()
        // Byte strings always encode.
        for v in values { out += (try? Descriptors.encode(bytesType, .bytes(v), [:])) ?? [] }
        return out
    }

    public static func readFields(_ count: Int, _ bytes: [UInt8], _ start: Int) throws -> ([[UInt8]], Int) {
        let (values, next) = try Wire.readFields(Array(repeating: bytesType, count: count), bytes, start)
        return (try values.map { v in
            guard case .bytes(let b) = v else { throw Fail.with("InvalidSecureRecord") }
            return b
        }, next)
    }

    public static func identity(_ seed: [UInt8]) throws -> NodeIdentity {
        try Fail.require(seed.count == 32, "InvalidNodeIdentity")
        return NodeIdentity(seed: seed, publicKey: CryptoPrimitives.mldsaPublic(seed))
    }

    public static func fingerprint(_ identity: NodeIdentity) -> String { Wire.hex(CryptoPrimitives.sha3(identity.publicKey)) }

    public static func hello(_ session: [UInt8], _ address: String, _ publicKey: [UInt8], _ kem: [UInt8]) -> [UInt8] {
        fields([session, Array(address.utf8), publicKey, kem])
    }

    public static func welcome(_ session: [UInt8], _ address: String, _ publicKey: [UInt8], _ ciphertext: [UInt8], _ helloBody: [UInt8]) -> [UInt8] {
        fields([session, Array(address.utf8), publicKey, ciphertext, CryptoPrimitives.sha3(helloBody)])
    }

    public static func key(_ shared: [UInt8], _ helloBody: [UInt8], _ welcomeBody: [UInt8]) -> [UInt8] {
        CryptoPrimitives.shake(shared + Array("lawspec-session-v1".utf8) + CryptoPrimitives.sha3(helloBody) + CryptoPrimitives.sha3(welcomeBody), 32)
    }

    public static func record(_ kind: UInt8, _ body: [UInt8], _ signature: [UInt8]) -> [UInt8] {
        [76, 83, 1, kind] + body + fields([signature])
    }

    /// A parsed record.
    public enum Record {
        case handshake(kind: Int, values: [[UInt8]], body: [UInt8], signature: [UInt8])
        case sealed(session: [UInt8], direction: Int, sealedBytes: [UInt8])
    }

    public static func read(_ bytes: [UInt8]) throws -> Record {
        let invalid = Fail.with("InvalidSecureRecord")
        guard bytes.count >= 4, bytes[0] == 76, bytes[1] == 83, bytes[2] == 1 else { throw invalid }
        switch bytes[3] {
        case 1, 2:
            let (values, rest) = try readFields(bytes[3] == 1 ? 4 : 5, bytes, 4)
            let (signature, next) = try readFields(1, bytes, rest)
            guard next == bytes.count else { throw invalid }
            return .handshake(kind: Int(bytes[3]), values: values, body: Array(bytes[4..<rest]), signature: signature[0])
        case 3:
            let (session, at) = try readFields(1, bytes, 4)
            guard at < bytes.count else { throw invalid }
            let direction = Int(bytes[at])
            let (sealedBytes, next) = try readFields(1, bytes, at + 1)
            guard next == bytes.count else { throw invalid }
            return .sealed(session: session[0], direction: direction, sealedBytes: sealedBytes[0])
        default:
            throw invalid
        }
    }

    private static func associated(_ session: [UInt8], _ direction: Int) -> [UInt8] {
        Array("lawspec-frame-v1".utf8) + session + [UInt8(truncatingIfNeeded: direction)]
    }

    /// A frame sealed under a session key with a given nonce.
    public static func sealWith(_ key: [UInt8], _ session: [UInt8], _ direction: Int, _ frame: [UInt8], _ nonce: [UInt8]) throws -> [UInt8] {
        let sealedBytes: [UInt8]
        do { sealedBytes = nonce + (try CryptoPrimitives.aes256GcmEncrypt(key, nonce, frame, associated(session, direction))) } catch {
            throw Fail.with("InvalidSecureRecord", error.description)
        }
        return [76, 83, 1, 3] + fields([session]) + [UInt8(truncatingIfNeeded: direction)] + fields([sealedBytes])
    }

    public static func seal(_ key: [UInt8], _ session: [UInt8], _ direction: Int, _ frame: [UInt8]) throws -> [UInt8] {
        try sealWith(key, session, direction, frame, CryptoPrimitives.randomBytes(12))
    }

    public static func openSealed(_ key: [UInt8], _ session: [UInt8], _ direction: Int, _ sealedBytes: [UInt8]) -> [UInt8]? {
        if sealedBytes.count < 12 + 16 { return nil }
        return CryptoPrimitives.aes256GcmDecrypt(key, Array(sealedBytes[0..<12]), Array(sealedBytes[12...]), associated(session, direction))
    }

    /// Signing and the KEM, as LawSpec failures.
    static func sign(_ seed: [UInt8], _ message: [UInt8]) throws -> [UInt8] {
        do { return try CryptoPrimitives.mldsaSign(seed, message) } catch { throw Fail.with("SecureNetwork", error.description) }
    }

    static func encapsulate(_ publicKey: [UInt8]) throws -> ([UInt8], [UInt8]) {
        do {
            let (c, s) = try CryptoPrimitives.mlkemEncapsulate(publicKey)
            return (c, s)
        } catch { throw Fail.with("InvalidHello", error.description) }
    }

    static func decapsulate(_ seed: [UInt8], _ ciphertext: [UInt8]) throws -> [UInt8] {
        do { return try CryptoPrimitives.mlkemDecapsulate(seed, ciphertext) } catch { throw Fail.with("InvalidWelcome", error.description) }
    }
}
