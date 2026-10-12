// The public network API (lawspec_network on BEAM): node options and
// identities, transports, in-memory networks and owned nodes.
// ref:DEC-distribution-canonical-wire

public enum Network {
    /// Options with no identity (a new one per node, or the configured one)
    /// and the configured trust.
    public static func options() -> NetworkOptions { NetworkConfig.empty }

    public static func withIdentity(_ options: NetworkOptions, _ identity: NodeIdentity) -> NetworkOptions {
        var o = options
        o.identity = identity
        return o
    }

    /// Trust exactly these fingerprints.
    public static func withTrusted(_ options: NetworkOptions, _ fingerprints: [String]) -> NetworkOptions {
        var o = options
        o.trusted = fingerprints
        o.trustGiven = true
        return o
    }

    /// Trust any peer whose handshake verifies.
    public static func trustOnFirstUse(_ options: NetworkOptions) -> NetworkOptions {
        var o = options
        o.trusted = nil
        o.trustGiven = true
        return o
    }

    public static func identityFromSeed(_ seed: [UInt8]) throws -> NodeIdentity { try NetworkRecords.identity(seed) }

    public static func newIdentity() throws -> NodeIdentity { try identityFromSeed(CryptoPrimitives.randomBytes(32)) }

    public static func publicKey(_ identity: NodeIdentity) -> [UInt8] { identity.publicKey }

    public static func fingerprint(_ identity: NodeIdentity) -> String { NetworkRecords.fingerprint(identity) }

    public static func tcp(_ host: String, _ port: Int) -> Transport { Transports.tcp(host, port) }

    public static func http(_ host: String, _ port: Int) -> Transport { Transports.http(host, port) }

    public static func advertise(_ transport: Transport, _ host: String) throws -> Transport { try Transports.advertise(transport, host) }

    /// Memory network options: seed, loss and duplicate chances, the most
    /// delay in seconds, and whether to record frames.
    public static func memoryOptions(_ seed: BigInt, _ loss: Double, _ duplicate: Double, _ delay: Double, _ record: Bool) -> MemoryOptions {
        MemoryOptions(seed: seed, loss: loss, duplicate: duplicate, delay: delay, record: record)
    }

    public static func memory(_ options: MemoryOptions) throws -> MemoryNetwork { try MemoryNetwork(options) }

    public static func withMemory<T>(_ options: MemoryOptions, _ body: (MemoryNetwork) throws -> T) throws -> T {
        let network = try memory(options)
        defer { network.close() }
        return try body(network)
    }

    public static func closeMemory(_ network: MemoryNetwork) { network.close() }

    public static func memoryTransport(_ network: MemoryNetwork, _ name: String) -> Transport { Transports.memory(network, name) }

    /// A memory transport without the secure layer, for tests only.
    public static func insecureMemoryTransportForTests(_ network: MemoryNetwork, _ name: String) -> Transport {
        Transports.insecureMemoryForTests(network, name)
    }

    public static func partition(_ network: MemoryNetwork, _ groups: [[String]]) throws { try network.partition(groups) }

    public static func heal(_ network: MemoryNetwork) { network.heal() }

    public static func recorded(_ network: MemoryNetwork) -> [[UInt8]] { network.recorded() }

    public static func openNode(_ transport: Transport, _ options: NetworkOptions) throws -> Node {
        do {
            return try Node(transport, options)
        } catch let e as LawSpecError where e.code != "Network" {
            throw Fail.with("Network", e.detail.isEmpty ? e.code : e.code + ": " + e.detail)
        }
    }

    public static func close(_ node: Node) { node.close() }

    public static func withNode<T>(_ transport: Transport, _ options: NetworkOptions, _ body: (Node) throws -> T) throws -> T {
        let node = try openNode(transport, options)
        defer { node.close() }
        return try body(node)
    }

    public static func address(_ node: Node) -> String { node.address }

    public static func nodeFingerprint(_ node: Node) throws -> String { try node.identity() }

    /// The wire encodings, in hexadecimal, of count values a descriptor text
    /// draws from a seed at a size (the distribution suite's vectors).
    public static func wireEncoded(_ text: String, _ seed: BigInt, _ size: Int, _ count: Int) throws -> [String] {
        let (table, d) = try Descriptors.fromText(text)
        var state = Random.seed(seed)
        var out = [String]()
        for _ in 0..<max(0, count) {
            let (v, next) = try Descriptors.generate(d, table, state, size)
            state = next
            out.append(Wire.hex(try Descriptors.encode(d, v, table)))
        }
        return out
    }

    /// Whether count values a descriptor text draws decode to themselves.
    public static func wireRoundTrips(_ text: String, _ seed: BigInt, _ size: Int, _ count: Int) throws -> Bool {
        let (table, d) = try Descriptors.fromText(text)
        var state = Random.seed(seed)
        var all = true
        for _ in 0..<max(0, count) {
            let (v, next) = try Descriptors.generate(d, table, state, size)
            state = next
            let back = try Descriptors.decode(d, try Descriptors.encode(d, v, table), table)
            if Descriptors.render(back) != Descriptors.render(v) { all = false }
        }
        return all
    }

    /// Whether this runtime's secure handshake gives a cross-target vector's
    /// bytes: the hello and welcome hashes, the session key and a sealed frame
    /// (all in hexadecimal) from the two identities' and the KEM key's seeds.
    public static func handshakeVector(_ initiatorSeed: String, _ responderSeed: String, _ kemSeed: String, _ session: String, _ initiator: String,
                                       _ responder: String, _ ciphertext: String, _ nonce: String, _ frame: String, _ helloHash: String,
                                       _ welcomeHash: String, _ key: String, _ record: String) -> Bool {
        guard let first = Wire.unhex(initiatorSeed), let second = Wire.unhex(responderSeed), let kemSeedBytes = Wire.unhex(kemSeed),
              let sessionBytes = Wire.unhex(session), let ciphertextBytes = Wire.unhex(ciphertext), let nonceBytes = Wire.unhex(nonce),
              let frameBytes = Wire.unhex(frame) else { return false }
        do {
            let a = try NetworkRecords.identity(first)
            let b = try NetworkRecords.identity(second)
            let (kemPublic, kemSecret) = CryptoPrimitives.mlkemKeyPair(kemSeedBytes)
            let hello = NetworkRecords.hello(sessionBytes, initiator, a.publicKey, kemPublic)
            let welcome = NetworkRecords.welcome(sessionBytes, responder, b.publicKey, ciphertextBytes, hello)
            let derived = NetworkRecords.key(try NetworkRecords.decapsulate(kemSecret, ciphertextBytes), hello, welcome)
            let sealedRecord = try NetworkRecords.sealWith(derived, sessionBytes, 0, frameBytes, nonceBytes)
            let sealedBytes = nonceBytes + (try CryptoPrimitives.aes256GcmEncrypt(derived, nonceBytes, frameBytes,
                                                                                    Array("lawspec-frame-v1".utf8) + sessionBytes + [0]))
            return Wire.hex(CryptoPrimitives.sha3(hello)) == helloHash
                && Wire.hex(CryptoPrimitives.sha3(welcome)) == welcomeHash
                && Wire.hex(derived) == key
                && Wire.hex(sealedRecord) == record
                && NetworkRecords.openSealed(derived, sessionBytes, 0, sealedBytes) == frameBytes
        } catch {
            return false
        }
    }
}
