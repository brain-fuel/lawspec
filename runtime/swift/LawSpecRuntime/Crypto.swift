// lawspec.crypto's default handlers in Swift, over portable values: SHA3-256
// and SHAKE256, ML-KEM-768 key exchange, ML-DSA-65 signatures (and SLH-DSA
// for programs that choose it), and AES-256-GCM. The primitives come from
// CryptoPrimitives: CryptoKit where it has the operation, the runtime's own
// code where it does not. ref:DEC-swift-runtime-from-scratch

public enum Crypto {
    private static func fail(_ code: String, _ detail: String = "") -> LawSpecError { Fail.with(code, detail) }

    private static func tag(_ name: String) -> String { "lawspec.crypto::type::" + name + "::" + name }
    private static func wrap(_ name: String, _ bytes: [UInt8]) -> Value { .data(tag(name), [.bytes(bytes)]) }
    private static func pair(_ name: String, _ first: Value, _ second: Value) -> Value { .data(tag(name), [first, second]) }

    private static func unwrap(_ name: String, _ value: Value) throws -> [UInt8] {
        guard case .data(let t, let fields) = value, t == tag(name), fields.count == 1, case .bytes(let b) = fields[0] else {
            throw fail("InvalidCryptoValue", name)
        }
        return b
    }

    private static func bytes(_ value: Value) throws -> [UInt8] {
        guard case .bytes(let b) = value else { throw fail("BytesRequired") }
        return b
    }

    /// A primitive's failure as LawSpec's.
    private static func checked<T>(_ body: () throws(CryptoFailure) -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw fail(error.code, error.detail)
        }
    }

    private static func signatureHandler(
        _ make: @escaping @Sendable () -> ([UInt8], [UInt8]),
        _ sign: @escaping @Sendable ([UInt8], [UInt8]) throws(CryptoFailure) -> [UInt8],
        _ verify: @escaping @Sendable ([UInt8], [UInt8], [UInt8]) -> Bool
    ) -> Effects.Handler {
        Effects.stateless([
            ("signingKeyPair", { _, _ in
                let (publicKey, secret) = make()
                return pair("SigningKeyPair", wrap("VerifyingKey", publicKey), wrap("SigningKey", secret))
            }),
            ("sign", { _, args in
                guard args.count == 2 else { throw fail("InvalidArguments", "sign") }
                let secret = try unwrap("SigningKey", args[0])
                let message = try bytes(args[1])
                return wrap("SignatureBytes", try checked { () throws(CryptoFailure) -> [UInt8] in try sign(secret, message) })
            }),
            ("verify", { _, args in
                guard args.count == 3 else { throw fail("InvalidArguments", "verify") }
                return .bool(verify(try unwrap("VerifyingKey", args[0]), try bytes(args[1]), try unwrap("SignatureBytes", args[2])))
            }),
        ])
    }

    /// The SLH-DSA-SHAKE-128f handler of Signature: stateless hash-based
    /// signatures, for programs that choose them over ML-DSA.
    public static func slhDsaSignatureHandler() -> Effects.Handler {
        signatureHandler({ CryptoPrimitives.slhKeyPair() }, { secret, message throws(CryptoFailure) in
            try CryptoPrimitives.slhSign(secret, message)
        }, { CryptoPrimitives.slhVerify($0, $1, $2) })
    }

    /// The default handler of a lawspec.crypto ability.
    public static func handler(_ key: String) throws -> Effects.Handler {
        switch key {
        case "lawspec.crypto::ability::Hash":
            return Effects.stateless([
                ("sha3", { _, args in wrap("Digest", CryptoPrimitives.sha3(try bytes(args[0]))) }),
                ("shake", { _, args in
                    guard args.count == 2, case .int(let count) = args[1] else { throw fail("InvalidArguments", "shake") }
                    let n = count > BigInt(Int(Int32.max)) ? Int(Int32.max) : (count.exactly(Int.self) ?? 0)
                    return .bytes(CryptoPrimitives.shake(try bytes(args[0]), Swift.max(0, n)))
                }),
            ])
        case "lawspec.crypto::ability::KeyExchange":
            return Effects.stateless([
                ("exchangeKeyPair", { _, _ in
                    let (publicKey, secret) = CryptoPrimitives.mlkemKeyPair(CryptoPrimitives.randomBytes(64))
                    return pair("ExchangeKeyPair", wrap("ExchangePublicKey", publicKey), wrap("ExchangeSecretKey", secret))
                }),
                ("encapsulate", { _, args in
                    let publicKey = try unwrap("ExchangePublicKey", args[0])
                    let (ciphertext, shared) = try checked { () throws(CryptoFailure) in try CryptoPrimitives.mlkemEncapsulate(publicKey) }
                    return pair("Encapsulated", wrap("Ciphertext", ciphertext), wrap("SharedSecret", shared))
                }),
                ("decapsulate", { _, args in
                    guard args.count == 2 else { throw fail("InvalidArguments", "decapsulate") }
                    let secret = try unwrap("ExchangeSecretKey", args[0])
                    let ciphertext = try unwrap("Ciphertext", args[1])
                    return wrap("SharedSecret", try checked { () throws(CryptoFailure) in try CryptoPrimitives.mlkemDecapsulate(secret, ciphertext) })
                }),
            ])
        case "lawspec.crypto::ability::Signature":
            return signatureHandler({
                let seed = CryptoPrimitives.randomBytes(32)
                return (CryptoPrimitives.mldsaPublic(seed), seed)
            }, { secret, message throws(CryptoFailure) in
                try CryptoPrimitives.mldsaSign(secret, message)
            }, { CryptoPrimitives.mldsaVerify($0, $1, $2) })
        case "lawspec.crypto::ability::Aead":
            return Effects.stateless([
                ("aeadKey", { _, _ in wrap("AeadKey", CryptoPrimitives.randomBytes(32)) }),
                ("deriveAeadKey", { _, args in
                    guard args.count == 2 else { throw fail("InvalidArguments", "deriveAeadKey") }
                    return wrap("AeadKey", CryptoPrimitives.deriveAeadKey(try unwrap("SharedSecret", args[0]), try bytes(args[1])))
                }),
                ("seal", { _, args in
                    guard args.count == 3 else { throw fail("InvalidArguments", "seal") }
                    let key = try unwrap("AeadKey", args[0])
                    let message = try bytes(args[1])
                    let associated = try bytes(args[2])
                    return wrap("Sealed", try checked { () throws(CryptoFailure) in try CryptoPrimitives.seal(key, message, associated) })
                }),
                ("unseal", { _, args in
                    guard args.count == 3 else { throw fail("InvalidArguments", "unseal") }
                    guard let message = CryptoPrimitives.unseal(try unwrap("AeadKey", args[0]), try unwrap("Sealed", args[1]), try bytes(args[2])) else {
                        return .data("Maybe::Nothing", [])
                    }
                    return .data("Maybe::Just", [.bytes(message)])
                }),
            ])
        default:
            throw fail("UnknownDefaultHandler", key)
        }
    }

    /// Make Defaults.handler answer the lawspec.crypto abilities. The generated
    /// schema of a program that uses lawspec.crypto calls this once.
    public static func install() {
        Defaults.cryptoHandler.with { $0 = { key in try handler(key) } }
    }
}
