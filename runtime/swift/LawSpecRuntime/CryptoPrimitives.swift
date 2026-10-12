// LawSpec's post-quantum crypto defaults on Swift: SHA3-256 and SHAKE256
// (FIPS 202), ML-KEM-768 (FIPS 203), ML-DSA-65 (FIPS 204), SLH-DSA-SHAKE-128f
// (FIPS 205) and AES-256-GCM (SP 800-38D). Keys are stored as their FIPS
// key-generation seeds, as on every target, so the portable values are the
// same. CryptoKit is used wherever it has the operation; the pure-Swift
// fallbacks (Keccak, MLKEM768Fallback, MLDSA65Fallback, SLHDSAShake128f)
// cover only what it lacks. ref:DEC-typed-core-boundary

import CryptoKit
import Foundation

/// A crypto operation's failure: a code, as on every target, and a detail.
public struct CryptoFailure: Error, Sendable, CustomStringConvertible {
    public let code: String
    public let detail: String

    public init(code: String, detail: String = "") {
        self.code = code
        self.detail = detail
    }

    public var description: String { detail.isEmpty ? code : code + " " + detail }
}

/// The byte-level crypto primitives behind lawspec.crypto and the secure
/// network transport.
public enum CryptoPrimitives {
    private static func fail(_ code: String, _ detail: String = "") -> CryptoFailure {
        CryptoFailure(code: code, detail: detail)
    }

    /// Fresh random bytes from the operating system.
    public static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<max(0, count)).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    // MARK: FIPS 202

    /// SHA3-256 of a message.
    public static func sha3(_ message: [UInt8]) -> [UInt8] {
        Array(SHA3_256.hash(data: message))
    }

    /// SHAKE256 of a message, a number of bytes long (none when it is not
    /// positive). CryptoKit has no SHAKE, so this uses the Keccak fallback.
    public static func shake(_ message: [UInt8], _ count: Int) -> [UInt8] {
        count <= 0 ? [] : Keccak.shake256(message, count)
    }

    /// An AES-256-GCM key for a shared secret and a context.
    public static func deriveAeadKey(_ secret: [UInt8], _ context: [UInt8]) -> [UInt8] {
        shake(secret + context, 32)
    }

    // MARK: FIPS 203: ML-KEM-768, keys held as their 64-byte seed d || z

    /// The encapsulation key and the expanded decapsulation key of a seed. The
    /// public key is CryptoKit's; the expanded key, which CryptoKit never
    /// exposes, is the fallback's.
    public static func mlkemExpand(_ seed: [UInt8]) -> (publicKey: [UInt8], privateKey: [UInt8]) {
        precondition(seed.count == 64, "InvalidMlKemSeed")
        let expanded = MLKEM768Fallback.keyGen(seed)
        if let key = try? MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil) {
            return (Array(key.publicKey.rawRepresentation), expanded.privateKey)
        }
        return expanded
    }

    /// A key pair from a seed: the public key, and the seed it is kept as.
    public static func mlkemKeyPair(_ seed: [UInt8]) -> (publicKey: [UInt8], seed: [UInt8]) {
        (mlkemExpand(seed).publicKey, seed)
    }

    /// Encapsulate a fresh shared secret: the ciphertext and the secret.
    public static func mlkemEncapsulate(_ publicKey: [UInt8]) throws(CryptoFailure) -> (ciphertext: [UInt8], shared: [UInt8]) {
        guard publicKey.count == MLKEM768Fallback.publicKeyLength,
              let key = try? MLKEM768.PublicKey(rawRepresentation: publicKey),
              let result = try? key.encapsulate()
        else { throw fail("InvalidMlKemPublicKey") }
        let shared = result.sharedSecret.withUnsafeBytes { Array($0) }
        return (Array(result.encapsulated), shared)
    }

    /// FIPS 203's deterministic encapsulation with a given 32-byte message,
    /// for known-answer tests only. CryptoKit always draws the message at
    /// random, so this uses the fallback.
    public static func mlkemEncapsulateWith(_ publicKey: [UInt8], _ message: [UInt8]) throws(CryptoFailure) -> (ciphertext: [UInt8], shared: [UInt8]) {
        guard message.count == 32 else { throw fail("InvalidMlKemMessage") }
        guard MLKEM768Fallback.validPublicKey(publicKey) else { throw fail("InvalidMlKemPublicKey") }
        return MLKEM768Fallback.encapsulate(publicKey, message)
    }

    /// Decapsulate with an expanded decapsulation key. CryptoKit cannot
    /// import one, so this uses the fallback.
    public static func mlkemDecapsulateExpanded(_ privateKey: [UInt8], _ ciphertext: [UInt8]) throws(CryptoFailure) -> [UInt8] {
        guard privateKey.count == MLKEM768Fallback.privateKeyLength else { throw fail("InvalidMlKemPrivateKey") }
        guard ciphertext.count == MLKEM768Fallback.ciphertextLength else { throw fail("InvalidMlKemCiphertext") }
        return MLKEM768Fallback.decapsulate(privateKey, ciphertext)
    }

    /// Decapsulate with a key kept as its seed.
    public static func mlkemDecapsulate(_ seed: [UInt8], _ ciphertext: [UInt8]) throws(CryptoFailure) -> [UInt8] {
        guard seed.count == 64 else { throw fail("InvalidMlKemSeed") }
        guard ciphertext.count == MLKEM768Fallback.ciphertextLength else { throw fail("InvalidMlKemCiphertext") }
        guard let key = try? MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil),
              let shared = try? key.decapsulate(ciphertext)
        else { throw fail("InvalidMlKemCiphertext") }
        return shared.withUnsafeBytes { Array($0) }
    }

    // MARK: FIPS 204: ML-DSA-65, signing keys held as their 32-byte seed

    /// The public key and the expanded private key of a seed. The public key
    /// is CryptoKit's; the expanded key, which CryptoKit never exposes, is the
    /// fallback's.
    public static func mldsaExpand(_ seed: [UInt8]) -> (publicKey: [UInt8], privateKey: [UInt8]) {
        precondition(seed.count == 32, "InvalidMlDsaSeed")
        let expanded = MLDSA65Fallback.keyGen(seed)
        return (mldsaPublic(seed), expanded.privateKey)
    }

    /// The public key of a seed.
    public static func mldsaPublic(_ seed: [UInt8]) -> [UInt8] {
        precondition(seed.count == 32, "InvalidMlDsaSeed")
        if let key = try? MLDSA65.PrivateKey(seedRepresentation: seed, publicKey: nil) {
            return Array(key.publicKey.rawRepresentation)
        }
        return MLDSA65Fallback.keyGen(seed).publicKey
    }

    /// Sign with a context string; deterministic for known-answer tests (the
    /// fallback, since CryptoKit always hedges), hedged otherwise (CryptoKit).
    public static func mldsaSignWith(_ seed: [UInt8], _ message: [UInt8], _ context: [UInt8], deterministic: Bool) throws(CryptoFailure) -> [UInt8] {
        guard seed.count == 32, context.count <= 255 else { throw fail("InvalidMlDsaSignature") }
        if deterministic {
            return MLDSA65Fallback.sign(seed, message, context, randomness: [UInt8](repeating: 0, count: 32))
        }
        guard let key = try? MLDSA65.PrivateKey(seedRepresentation: seed, publicKey: nil),
              let signature = try? key.signature(for: message, context: context)
        else { throw fail("InvalidMlDsaSignature") }
        return Array(signature)
    }

    /// Sign a message (hedged, with no context).
    public static func mldsaSign(_ seed: [UInt8], _ message: [UInt8]) throws(CryptoFailure) -> [UInt8] {
        try mldsaSignWith(seed, message, [], deterministic: false)
    }

    /// Verify a signature with a context string; a malformed key or signature
    /// does not verify.
    public static func mldsaVerifyWith(_ publicKey: [UInt8], _ message: [UInt8], _ signature: [UInt8], _ context: [UInt8]) -> Bool {
        guard publicKey.count == MLDSA65Fallback.publicKeyLength, signature.count == MLDSA65Fallback.signatureLength,
              context.count <= 255, let key = try? MLDSA65.PublicKey(rawRepresentation: publicKey)
        else { return false }
        return key.isValidSignature(signature, for: message, context: context)
    }

    public static func mldsaVerify(_ publicKey: [UInt8], _ message: [UInt8], _ signature: [UInt8]) -> Bool {
        mldsaVerifyWith(publicKey, message, signature, [])
    }

    // MARK: FIPS 205: SLH-DSA-SHAKE-128f, private keys of 64 bytes (fallback: CryptoKit has none)

    /// A fresh key pair: the public key and the private key.
    public static func slhKeyPair() -> (publicKey: [UInt8], privateKey: [UInt8]) {
        SLHDSAShake128f.keyGen(randomBytes(48))
    }

    /// The key pair of the 48 bytes SK.seed || SK.prf || PK.seed (known-answer
    /// tests only).
    public static func slhKeyPairOf(_ seed: [UInt8]) -> (publicKey: [UInt8], privateKey: [UInt8]) {
        precondition(seed.count == 48, "InvalidSlhDsaSeed")
        return SLHDSAShake128f.keyGen(seed)
    }

    /// Sign with a context string, hedged with fresh randomness.
    public static func slhSignWith(_ privateKey: [UInt8], _ message: [UInt8], _ context: [UInt8]) throws(CryptoFailure) -> [UInt8] {
        guard privateKey.count == SLHDSAShake128f.privateKeyLength, context.count <= 255 else { throw fail("InvalidSlhDsaSignature") }
        return SLHDSAShake128f.sign(privateKey, message, context, additionalRandomness: randomBytes(SLHDSAShake128f.n))
    }

    public static func slhSign(_ privateKey: [UInt8], _ message: [UInt8]) throws(CryptoFailure) -> [UInt8] {
        try slhSignWith(privateKey, message, [])
    }

    /// Verify with a context string; a malformed key or signature does not verify.
    public static func slhVerifyWith(_ publicKey: [UInt8], _ message: [UInt8], _ signature: [UInt8], _ context: [UInt8]) -> Bool {
        SLHDSAShake128f.verify(publicKey, message, signature, context)
    }

    public static func slhVerify(_ publicKey: [UInt8], _ message: [UInt8], _ signature: [UInt8]) -> Bool {
        slhVerifyWith(publicKey, message, signature, [])
    }

    // MARK: SP 800-38D: AES-256-GCM with a 96-bit nonce and a 128-bit tag

    /// The ciphertext followed by its tag.
    public static func aes256GcmEncrypt(_ key: [UInt8], _ nonce: [UInt8], _ message: [UInt8], _ associated: [UInt8]) throws(CryptoFailure) -> [UInt8] {
        guard key.count == 32, nonce.count == 12, let gcmNonce = try? AES.GCM.Nonce(data: nonce),
              let sealed = try? AES.GCM.seal(message, using: SymmetricKey(data: key), nonce: gcmNonce, authenticating: associated)
        else { throw fail("InvalidAeadKey") }
        return Array(sealed.ciphertext) + Array(sealed.tag)
    }

    /// The plaintext, or nil when the tag does not verify.
    public static func aes256GcmDecrypt(_ key: [UInt8], _ nonce: [UInt8], _ sealed: [UInt8], _ associated: [UInt8]) -> [UInt8]? {
        guard key.count == 32, nonce.count == 12, sealed.count >= 16, let gcmNonce = try? AES.GCM.Nonce(data: nonce) else { return nil }
        let size = sealed.count - 16
        guard let box = try? AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: sealed[0..<size], tag: sealed[size...]),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: associated)
        else { return nil }
        return Array(plaintext)
    }

    /// A fresh nonce, then the sealed message.
    public static func seal(_ key: [UInt8], _ message: [UInt8], _ associated: [UInt8]) throws(CryptoFailure) -> [UInt8] {
        let nonce = randomBytes(12)
        return nonce + (try aes256GcmEncrypt(key, nonce, message, associated))
    }

    /// Open what seal made, or nil.
    public static func unseal(_ key: [UInt8], _ sealed: [UInt8], _ associated: [UInt8]) -> [UInt8]? {
        guard sealed.count >= 12 else { return nil }
        return aes256GcmDecrypt(key, Array(sealed[0..<12]), Array(sealed[12...]), associated)
    }
}
