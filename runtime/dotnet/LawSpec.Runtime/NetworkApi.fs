namespace LawSpec.Runtime

open System.Numerics
open System.Security.Cryptography

/// The public network API (lawspec_network on BEAM): node options and
/// identities, transports, in-memory networks and owned nodes.
/// ref:DEC-distribution-canonical-wire
module Network =
    /// Options with no identity (a new one per node, or the configured one)
    /// and the configured trust.
    [<CompiledName("Options")>]
    let options () = NetworkConfig.empty

    [<CompiledName("WithIdentity")>]
    let withIdentity (options: NetworkOptions) (identity: NodeIdentity) =
        { options with
            Identity = Some identity
        }

    /// Trust exactly these fingerprints.
    [<CompiledName("WithTrusted")>]
    let withTrusted (options: NetworkOptions) (fingerprints: string list) =
        { options with
            Trusted = Some fingerprints
            TrustGiven = true
        }

    /// Trust any peer whose handshake verifies.
    [<CompiledName("TrustOnFirstUse")>]
    let trustOnFirstUse (options: NetworkOptions) =
        { options with
            Trusted = None
            TrustGiven = true
        }

    [<CompiledName("IdentityFromSeed")>]
    let identityFromSeed (seed: byte[]) =
        NetworkRecords.identity (SecureNetwork.crypto ()) seed

    [<CompiledName("NewIdentity")>]
    let newIdentity () =
        identityFromSeed (RandomNumberGenerator.GetBytes 32)

    [<CompiledName("PublicKey")>]
    let publicKey (identity: NodeIdentity) = Array.copy identity.PublicKey

    [<CompiledName("Fingerprint")>]
    let fingerprint (identity: NodeIdentity) =
        NetworkRecords.fingerprint (SecureNetwork.crypto ()) identity

    [<CompiledName("Tcp")>]
    let tcp host port = Transports.tcp host port

    [<CompiledName("Http")>]
    let http host port = Transports.http host port

    [<CompiledName("Advertise")>]
    let advertise transport host = Transports.advertise transport host

    /// Memory network options: seed, loss and duplicate chances, the most
    /// delay in seconds, and whether to record frames.
    [<CompiledName("MemoryOptions")>]
    let memoryOptions (seed: BigInteger) loss duplicate delay record : MemoryOptions =
        {
            Seed = seed
            Loss = loss
            Duplicate = duplicate
            Delay = delay
            Record = record
        }

    [<CompiledName("Memory")>]
    let memory (options: MemoryOptions) = new MemoryNetwork(options)

    [<CompiledName("WithMemory")>]
    let withMemory (options: MemoryOptions) (body: MemoryNetwork -> 'a) : 'a =
        use network = memory options
        body network

    [<CompiledName("CloseMemory")>]
    let closeMemory (network: MemoryNetwork) = network.Close()

    [<CompiledName("MemoryTransport")>]
    let memoryTransport network name = Transports.memory network name

    /// A memory transport without the secure layer, for tests only.
    [<CompiledName("InsecureMemoryTransportForTests")>]
    let insecureMemoryTransportForTests network name =
        Transports.insecureMemoryForTests network name

    [<CompiledName("Partition")>]
    let partition (network: MemoryNetwork) (groups: string list list) = network.Partition groups

    [<CompiledName("Heal")>]
    let heal (network: MemoryNetwork) = network.Heal()

    [<CompiledName("Recorded")>]
    let recorded (network: MemoryNetwork) = network.Recorded()

    [<CompiledName("Open")>]
    let openNode (transport: Transport) (options: NetworkOptions) =
        try
            new Node(transport, options)
        with :? LawSpecException as e when e.Code <> "Network" && e.Code <> "SecureNetworkNotAvailable" ->
            Fail.raiseWith "Network" e.Message

    [<CompiledName("Close")>]
    let close (node: Node) = node.Close()

    [<CompiledName("WithNode")>]
    let withNode (transport: Transport) (options: NetworkOptions) (body: Node -> 'a) : 'a =
        let node = openNode transport options

        try
            body node
        finally
            close node

    [<CompiledName("Address")>]
    let address (node: Node) = node.Address

    [<CompiledName("NodeFingerprint")>]
    let nodeFingerprint (node: Node) = node.Identity

    /// The wire encodings, in hexadecimal, of count values a descriptor text
    /// draws from a seed at a size (the distribution suite's vectors).
    [<CompiledName("WireEncoded")>]
    let wireEncoded (text: string) (seed: BigInteger) (size: int) (count: int) : string list =
        let table, d = Descriptors.fromText text
        let mutable state = Random.seed seed

        [
            for _ in 1 .. max 0 count ->
                let v, next = Descriptors.generate d table state size
                state <- next
                Wire.hex (Descriptors.encode d v table)
        ]

    /// Whether count values a descriptor text draws decode to themselves.
    [<CompiledName("WireRoundTrips")>]
    let wireRoundTrips (text: string) (seed: BigInteger) (size: int) (count: int) : bool =
        let table, d = Descriptors.fromText text
        let mutable state = Random.seed seed

        Seq.forall
            id
            [
                for _ in 1 .. max 0 count ->
                    let v, next = Descriptors.generate d table state size
                    state <- next

                    Descriptors.render (Descriptors.decode d (Descriptors.encode d v table) table) =
                        Descriptors.render v
            ]

    /// Whether this runtime's secure handshake gives a cross-target vector's
    /// bytes: the hello and welcome hashes, the session key and a sealed frame
    /// (all in hexadecimal) from the two identities' and the KEM key's seeds.
    [<CompiledName("HandshakeVector")>]
    let handshakeVector
        (initiatorSeed: string)
        (responderSeed: string)
        (kemSeed: string)
        (session: string)
        (initiator: string)
        (responder: string)
        (ciphertext: string)
        (nonce: string)
        (frame: string)
        (helloHash: string)
        (welcomeHash: string)
        (key: string)
        (record: string)
        : bool =
        let crypto = SecureNetwork.crypto ()
        let bytes (text: string) = System.Convert.FromHexString text

        try
            let first = NetworkRecords.identity crypto (bytes initiatorSeed)
            let second = NetworkRecords.identity crypto (bytes responderSeed)
            let kemPublic, kemSecret = crypto.MlKemKeypair(bytes kemSeed)
            let hello = NetworkRecords.hello (bytes session) initiator first.PublicKey kemPublic

            let welcome =
                NetworkRecords.welcome crypto (bytes session) responder second.PublicKey (bytes ciphertext) hello

            let derived =
                NetworkRecords.key crypto (crypto.MlKemDecapsulate(kemSecret, bytes ciphertext)) hello welcome

            let sealedRecord =
                NetworkRecords.sealWith crypto derived (bytes session) 0 (bytes frame) (bytes nonce)

            let sealedBytes =
                Array.append
                    (bytes nonce)
                    (crypto.AesGcmEncrypt(
                        derived,
                        bytes nonce,
                        bytes frame,
                        Array.concat
                            [
                                System.Text.Encoding.ASCII.GetBytes "lawspec-frame-v1"
                                bytes session
                                [| 0uy |]
                            ]
                    ))

            Wire.hex (crypto.Sha3_256 hello) = helloHash
            && Wire.hex (crypto.Sha3_256 welcome) = welcomeHash
            && Wire.hex derived = key
            && Wire.hex sealedRecord = record
            && NetworkRecords.openSealed crypto derived (bytes session) 0 sealedBytes = Some(bytes frame)
        with _ ->
            false
