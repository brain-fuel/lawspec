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
    let withIdentity (options: NetworkOptions) (identity: NodeIdentity) = { options with Identity = Some identity }

    /// Trust exactly these fingerprints.
    [<CompiledName("WithTrusted")>]
    let withTrusted (options: NetworkOptions) (fingerprints: string list) =
        { options with Trusted = Some fingerprints; TrustGiven = true }

    /// Trust any peer whose handshake verifies.
    [<CompiledName("TrustOnFirstUse")>]
    let trustOnFirstUse (options: NetworkOptions) = { options with Trusted = None; TrustGiven = true }

    [<CompiledName("IdentityFromSeed")>]
    let identityFromSeed (seed: byte[]) = NetworkRecords.identity (SecureNetwork.crypto ()) seed

    [<CompiledName("NewIdentity")>]
    let newIdentity () = identityFromSeed (RandomNumberGenerator.GetBytes 32)

    [<CompiledName("PublicKey")>]
    let publicKey (identity: NodeIdentity) = Array.copy identity.PublicKey

    [<CompiledName("Fingerprint")>]
    let fingerprint (identity: NodeIdentity) = NetworkRecords.fingerprint (SecureNetwork.crypto ()) identity

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
        { Seed = seed; Loss = loss; Duplicate = duplicate; Delay = delay; Record = record }

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
    let insecureMemoryTransportForTests network name = Transports.insecureMemoryForTests network name

    [<CompiledName("Partition")>]
    let partition (network: MemoryNetwork) (groups: string list list) = network.Partition groups

    [<CompiledName("Heal")>]
    let heal (network: MemoryNetwork) = network.Heal()

    [<CompiledName("Recorded")>]
    let recorded (network: MemoryNetwork) = network.Recorded()

    [<CompiledName("Open")>]
    let openNode (transport: Transport) (options: NetworkOptions) =
        try new Node(transport, options)
        with :? LawSpecException as e when e.Code <> "Network" && e.Code <> "SecureNetworkNotAvailable" ->
            Fail.raiseWith "Network" e.Message

    [<CompiledName("Close")>]
    let close (node: Node) = node.Close()

    [<CompiledName("WithNode")>]
    let withNode (transport: Transport) (options: NetworkOptions) (body: Node -> 'a) : 'a =
        let node = openNode transport options
        try body node finally close node

    [<CompiledName("Address")>]
    let address (node: Node) = node.Address

    [<CompiledName("NodeFingerprint")>]
    let nodeFingerprint (node: Node) = node.Identity
