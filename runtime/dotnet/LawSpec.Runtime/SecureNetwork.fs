namespace LawSpec.Runtime

open System
open System.IO
open System.Security.Cryptography
open System.Threading
open System.Text

/// A node's identity: its ML-DSA-65 seed and public key.
type NodeIdentity = { Seed: byte[]; PublicKey: byte[] }

/// The cryptographic primitives the secure network layer needs, as the
/// crypto runtime (LawSpec.Runtime.NetworkCrypto, from lawspec.crypto's
/// default handlers) provides them: ML-DSA-65 keys from a 32-byte seed,
/// ML-KEM-768 keys from a 64-byte seed, SHA3-256, SHAKE256 and AES-256-GCM.
/// A program that imports lawspec.network installs one with SecureNetwork.install.
/// ref:DEC-distribution-canonical-wire
type INetworkCrypto =
    /// The ML-DSA-65 public key of a 32-byte seed.
    abstract MlDsaPublic: seed: byte[] -> byte[]
    abstract MlDsaSign: seed: byte[] * message: byte[] -> byte[]
    abstract MlDsaVerify: publicKey: byte[] * message: byte[] * signature: byte[] -> bool
    /// The ML-KEM-768 encapsulation key of a 64-byte seed, and the seed that
    /// decapsulates for it.
    abstract MlKemKeypair: seed: byte[] -> byte[] * byte[]
    /// A ciphertext and the shared secret it carries.
    abstract MlKemEncapsulate: encapsulationKey: byte[] -> byte[] * byte[]
    abstract MlKemDecapsulate: seed: byte[] * ciphertext: byte[] -> byte[]
    abstract Sha3_256: bytes: byte[] -> byte[]
    abstract Shake256: bytes: byte[] * length: int -> byte[]
    /// AES-256-GCM: the ciphertext followed by its 16-byte tag.
    abstract AesGcmEncrypt: key: byte[] * nonce: byte[] * plaintext: byte[] * associated: byte[] -> byte[]
    /// The plaintext of ciphertext-and-tag, or None when it does not authenticate.
    abstract AesGcmDecrypt: key: byte[] * nonce: byte[] * sealedBytes: byte[] * associated: byte[] -> byte[] option

/// The portable secure records, version 1: a signed hello carrying an
/// ephemeral ML-KEM key, a signed welcome carrying its ciphertext and the
/// hello's hash, a session key from SHAKE256, and AES-256-GCM sealed frames.
/// Every target writes the same bytes for the same seeds.
/// ref:DEC-distribution-canonical-wire
module NetworkRecords =
    let private bytesType = Descriptors.Forms [ Descriptors.Atom "bytes" ]

    [<CompiledName("Fields")>]
    let fields (values: byte[] list) =
        Wire.fields (values |> List.map (fun _ -> bytesType)) (values |> List.map Bytes)

    [<CompiledName("ReadFields")>]
    let readFields (count: int) (bytes: byte[]) (start: int) =
        let values, next = Wire.readFields (List.replicate count bytesType) bytes start

        values
        |> List.map (function
            | Bytes b -> b
            | _ -> Fail.raiseWith "InvalidSecureRecord" ""),
        next

    [<CompiledName("Identity")>]
    let identity (crypto: INetworkCrypto) (seed: byte[]) =
        if isNull seed || seed.Length <> 32 then
            Fail.raiseWith "InvalidNodeIdentity" ""

        {
            Seed = Array.copy seed
            PublicKey = crypto.MlDsaPublic seed
        }

    [<CompiledName("Fingerprint")>]
    let fingerprint (crypto: INetworkCrypto) (identity: NodeIdentity) =
        Wire.hex (crypto.Sha3_256 identity.PublicKey)

    [<CompiledName("Hello")>]
    let hello (session: byte[]) (address: string) (publicKey: byte[]) (kem: byte[]) =
        fields [ session; Encoding.UTF8.GetBytes address; publicKey; kem ]

    [<CompiledName("Welcome")>]
    let welcome
        (crypto: INetworkCrypto)
        (session: byte[])
        (address: string)
        (publicKey: byte[])
        (ciphertext: byte[])
        (helloBody: byte[])
        =
        fields
            [
                session
                Encoding.UTF8.GetBytes address
                publicKey
                ciphertext
                crypto.Sha3_256 helloBody
            ]

    [<CompiledName("Key")>]
    let key (crypto: INetworkCrypto) (shared: byte[]) (helloBody: byte[]) (welcomeBody: byte[]) =
        crypto.Shake256(
            Array.concat
                [
                    shared
                    Encoding.ASCII.GetBytes "lawspec-session-v1"
                    crypto.Sha3_256 helloBody
                    crypto.Sha3_256 welcomeBody
                ],
            32
        )

    [<CompiledName("Record")>]
    let record (kind: byte) (body: byte[]) (signature: byte[]) =
        Array.concat [ [| byte 'L'; byte 'S'; 1uy; kind |]; body; fields [ signature ] ]

    /// A parsed record.
    type Record =
        | Handshake of kind: int * values: byte[] list * body: byte[] * signature: byte[]
        | Sealed of session: byte[] * direction: int * sealedBytes: byte[]

    [<CompiledName("Read")>]
    let read (bytes: byte[]) : Record =
        if
            bytes.Length < 4
            || bytes.[0] <> byte 'L'
            || bytes.[1] <> byte 'S'
            || bytes.[2] <> 1uy
        then
            Fail.raiseWith "InvalidSecureRecord" ""

        match bytes.[3] with
        | 1uy
        | 2uy ->
            let count = if bytes.[3] = 1uy then 4 else 5
            let values, rest = readFields count bytes 4

            match readFields 1 bytes rest with
            | [ signature ], next when next = bytes.Length ->
                Handshake(int bytes.[3], values, bytes.[4 .. rest - 1], signature)
            | _ -> Fail.raiseWith "InvalidSecureRecord" ""
        | 3uy ->
            match readFields 1 bytes 4 with
            | [ session ], at when at < bytes.Length ->
                let direction = int bytes.[at]

                match readFields 1 bytes (at + 1) with
                | [ sealedBytes ], next when next = bytes.Length -> Sealed(session, direction, sealedBytes)
                | _ -> Fail.raiseWith "InvalidSecureRecord" ""
            | _ -> Fail.raiseWith "InvalidSecureRecord" ""
        | _ -> Fail.raiseWith "InvalidSecureRecord" ""

    let private associated (session: byte[]) (direction: int) =
        Array.concat [ Encoding.ASCII.GetBytes "lawspec-frame-v1"; session; [| byte direction |] ]

    /// A frame sealed under a session key with a given nonce.
    [<CompiledName("SealWith")>]
    let sealWith
        (crypto: INetworkCrypto)
        (key: byte[])
        (session: byte[])
        (direction: int)
        (frame: byte[])
        (nonce: byte[])
        =
        let sealedBytes =
            Array.append nonce (crypto.AesGcmEncrypt(key, nonce, frame, associated session direction))

        Array.concat
            [
                [| byte 'L'; byte 'S'; 1uy; 3uy |]
                fields [ session ]
                [| byte direction |]
                fields [ sealedBytes ]
            ]

    [<CompiledName("Seal")>]
    let seal crypto key session direction frame =
        sealWith crypto key session direction frame (RandomNumberGenerator.GetBytes 12)

    [<CompiledName("OpenSealed")>]
    let openSealed (crypto: INetworkCrypto) (key: byte[]) (session: byte[]) (direction: int) (sealedBytes: byte[]) =
        if sealedBytes.Length < 12 + 16 then
            None
        else
            crypto.AesGcmDecrypt(key, sealedBytes.[..11], sealedBytes.[12..], associated session direction)

/// A node's identity and the fingerprints it trusts (None: trust on first use).
type NetworkOptions =
    {
        Identity: NodeIdentity option
        IdentitySeed: byte[] option
        Trusted: string list option
        /// Whether Trusted was given (so the configuration file is not read for it).
        TrustGiven: bool
        FirstId: uint64 option
    }

/// Node identities and trust from options, then lawspec-network.conf (found
/// from the working directory up, or named by LAWSPEC_NETWORK_CONF), whose
/// `identity` line names a file of the seed in hexadecimal and whose
/// `trusted` line names a file of fingerprints.
/// ref:DEC-distribution-canonical-wire
module NetworkConfig =
    [<CompiledName("Empty")>]
    let empty =
        {
            Identity = None
            IdentitySeed = None
            Trusted = None
            TrustGiven = false
            FirstId = None
        }

    let private locate () =
        match Environment.GetEnvironmentVariable "LAWSPEC_NETWORK_CONF" with
        | null
        | "" ->
            let rec up (directory: string) =
                let path = Path.Combine(directory, "lawspec-network.conf")

                if File.Exists path then
                    Some path
                else
                    match Directory.GetParent directory with
                    | null -> None
                    | parent -> up parent.FullName

            up (Directory.GetCurrentDirectory())
        | file -> Some(Path.GetFullPath file)

    [<CompiledName("Configured")>]
    let configured () : byte[] option * string list option =
        match locate () with
        | None -> None, None
        | Some path when not (File.Exists path) -> None, None
        | Some path ->
            let directory = Path.GetDirectoryName path
            let mutable identity = None
            let mutable trusted = None

            for line in File.ReadAllLines path do
                let trimmed = line.Trim()

                for kind in [ "identity"; "trusted" ] do
                    if
                        trimmed.StartsWith(kind)
                        && trimmed.Length > kind.Length
                        && Char.IsWhiteSpace trimmed.[kind.Length]
                    then
                        let name = trimmed.Substring(kind.Length).Trim()
                        let text = File.ReadAllText(Path.Combine(directory, name))

                        if kind = "identity" then
                            identity <- Some(Convert.FromHexString(text.Trim()))
                        else
                            trusted <-
                                Some(
                                    text.Split([| ' '; '\t'; '\r'; '\n' |], StringSplitOptions.RemoveEmptyEntries)
                                    |> List.ofArray
                                )

            identity, trusted

    [<CompiledName("Fingerprint")>]
    let fingerprint (value: string) =
        if isNull value || value.Length <> 64 then
            Fail.raiseWith "InvalidTrustedFingerprint" ""

        Convert.FromHexString value |> ignore
        value.ToLowerInvariant()

    /// The identity and the trusted set to use.
    [<CompiledName("Resolve")>]
    let resolve (crypto: INetworkCrypto) (options: NetworkOptions) : NodeIdentity * Set<string> option =
        let fileIdentity, fileTrusted =
            if (options.Identity.IsSome || options.IdentitySeed.IsSome) && options.TrustGiven then
                None, None
            else
                configured ()

        let identity =
            match options.Identity, options.IdentitySeed, fileIdentity with
            | Some i, _, _ -> i
            | None, Some seed, _ -> NetworkRecords.identity crypto seed
            | None, None, Some seed -> NetworkRecords.identity crypto seed
            | None, None, None -> NetworkRecords.identity crypto (RandomNumberGenerator.GetBytes 32)

        let trusted = if options.TrustGiven then options.Trusted else fileTrusted
        identity, trusted |> Option.map (List.map fingerprint >> Set.ofList)

/// One owned security layer per node: signed ML-KEM handshakes, address-pinned
/// ML-DSA identities, and authenticated encrypted frames. Frames reach the
/// node only after they open under a session's key.
/// ref:DEC-distribution-canonical-wire ref:DEC-async-native-tasks
[<Sealed>]
type SecureLayer
    (crypto: INetworkCrypto, transport: Transport, options: NetworkOptions, deliver: string -> byte[] -> unit) =
    let identity, trusted = NetworkConfig.resolve crypto options
    let gate = obj ()
    let known = Collections.Generic.Dictionary<string, string>()
    let sessions = Collections.Generic.Dictionary<string, string * byte[] * int>()
    let outbound = Collections.Generic.Dictionary<string, byte[]>()
    let pending = Collections.Generic.Dictionary<string, PendingHandshake>()
    let welcomes = Collections.Generic.Dictionary<string, byte[] * byte[] * string>()
    let mutable connection: IPacketTransport = Unchecked.defaultof<_>
    let mutable closed = false
    let key (session: byte[]) = Convert.ToHexString session

    let accept (peer: string) (publicKey: byte[]) =
        let fingerprint = Wire.hex (crypto.Sha3_256 publicKey)

        match trusted with
        | Some set when not (set.Contains fingerprint) -> Fail.raiseWith "UntrustedPeer" peer
        | _ -> ()

        match known.TryGetValue peer with
        | true, existing when existing <> fingerprint -> Fail.raiseWith "PeerIdentityChanged" peer
        | _ -> known.[peer] <- fingerprint

    let validPeer (peer: string) =
        let node, name = Wire.splitAddress (peer + "/")

        if node <> peer || name <> "" then
            Fail.raiseWith "InvalidPeer" peer

    let signed (kind: byte) (prefix: string) (body: byte[]) =
        NetworkRecords.record
            kind
            body
            (crypto.MlDsaSign(identity.Seed, Array.append (Encoding.ASCII.GetBytes prefix) body))

    member private this.Wire(peer: string, bytes: byte[]) = connection.Send(peer, bytes)

    member private this.Incoming(record: byte[]) =
        let outgoingFrames = ResizeArray<string * byte[]>()
        let received = ResizeArray<string * byte[]>()

        lock gate (fun () ->
            match NetworkRecords.read record with
            | NetworkRecords.Handshake(1, [ session; peerBytes; publicKey; kem ], body, signature) ->
                if session.Length <> 16 || kem.Length <> 1184 then
                    Fail.raiseWith "InvalidHello" ""

                let peer = Encoding.UTF8.GetString peerBytes
                validPeer peer

                match welcomes.TryGetValue(key session) with
                | true, (hello, answer, from) ->
                    if from = peer && hello = record then
                        outgoingFrames.Add((peer, answer))
                | _ ->
                    if
                        sessions.ContainsKey(key session)
                        || pending.Values |> Seq.exists (fun p -> p.Session = session)
                    then
                        Fail.raiseWith "DuplicateSession" ""

                    if
                        not (
                            crypto.MlDsaVerify(
                                publicKey,
                                Array.append (Encoding.ASCII.GetBytes "lawspec-handshake-v1-hello") body,
                                signature
                            )
                        )
                    then
                        Fail.raiseWith "BadSignature" ""

                    accept peer publicKey
                    let ciphertext, shared = crypto.MlKemEncapsulate kem

                    let welcomeBody =
                        NetworkRecords.welcome crypto session connection.Address identity.PublicKey ciphertext body

                    let answer = signed 2uy "lawspec-handshake-v1-welcome" welcomeBody
                    let sessionKey = NetworkRecords.key crypto shared body welcomeBody
                    welcomes.[key session] <- (record, answer, peer)
                    sessions.[key session] <- (peer, sessionKey, 1)
                    outgoingFrames.Add((peer, answer))
            | NetworkRecords.Handshake(2, [ session; peerBytes; publicKey; ciphertext; hash ], body, signature) ->
                let peer = Encoding.UTF8.GetString peerBytes

                match pending.TryGetValue peer with
                | true, p when p.Session = session ->
                    if ciphertext.Length <> 1088 || hash <> crypto.Sha3_256 p.Body then
                        Fail.raiseWith "InvalidWelcome" ""

                    if
                        not (
                            crypto.MlDsaVerify(
                                publicKey,
                                Array.append (Encoding.ASCII.GetBytes "lawspec-handshake-v1-welcome") body,
                                signature
                            )
                        )
                    then
                        Fail.raiseWith "BadSignature" ""

                    accept peer publicKey

                    let sessionKey =
                        NetworkRecords.key crypto (crypto.MlKemDecapsulate(p.Seed, ciphertext)) p.Body body

                    p.Timer.Dispose()
                    pending.Remove peer |> ignore
                    sessions.[key session] <- (peer, sessionKey, 0)
                    outbound.[peer] <- session

                    for frame in p.Queue do
                        outgoingFrames.Add((peer, NetworkRecords.seal crypto sessionKey session 0 frame))
                | _ -> ()
            | NetworkRecords.Sealed(session, direction, sealedBytes) ->
                match sessions.TryGetValue(key session) with
                | true, (peer, sessionKey, own) when direction = 1 - own ->
                    match NetworkRecords.openSealed crypto sessionKey session direction sealedBytes with
                    | Some frame ->
                        received.Add((peer, frame))

                        if not (outbound.ContainsKey peer) then
                            outbound.[peer] <- session
                    | None -> ()
                | _ -> ()
            | _ -> ())

        for peer, bytes in outgoingFrames do
            this.Wire(peer, bytes) |> ignore

        for peer, frame in received do
            deliver peer frame

    member this.Start() =
        connection <-
            Transports.open' transport (fun _ bytes ->
                try
                    this.Incoming bytes
                with _ ->
                    ())

    member this.Address = connection.Address

    /// The SHA3-256 fingerprint of this node's public key.
    member this.Fingerprint = NetworkRecords.fingerprint crypto identity

    /// Seal a frame for a peer, after a handshake if there is no session yet.
    member this.Send(peer: string, frame: byte[]) : Result<unit, string> =
        let action =
            lock gate (fun () ->
                if closed then
                    Choice3Of3(Error "transport_closed")
                else
                    match outbound.TryGetValue peer with
                    | true, session ->
                        let _, sessionKey, direction = sessions.[key session]
                        Choice1Of3(NetworkRecords.seal crypto sessionKey session direction frame)
                    | _ ->
                        match pending.TryGetValue peer with
                        | true, p when p.Queue.Count < 4096 ->
                            p.Queue.Add frame
                            Choice3Of3(Ok())
                        | true, _ -> Choice3Of3(Error "handshake_queue_full")
                        | _ ->
                            let session = RandomNumberGenerator.GetBytes 16
                            let kem, seed = crypto.MlKemKeypair(RandomNumberGenerator.GetBytes 64)
                            let body = NetworkRecords.hello session connection.Address identity.PublicKey kem
                            let hello = signed 1uy "lawspec-handshake-v1-hello" body
                            let deadline = DateTime.UtcNow.AddSeconds 5.0

                            let p =
                                {
                                    Session = session
                                    Seed = seed
                                    Body = body
                                    Hello = hello
                                    Queue = ResizeArray [ frame ]
                                    Timer = null
                                }

                            pending.[peer] <- p

                            let timer =
                                new Timer(
                                    (fun _ ->
                                        let resend =
                                            lock gate (fun () ->
                                                match pending.TryGetValue peer with
                                                | true, q when obj.ReferenceEquals(q, p) ->
                                                    if DateTime.UtcNow >= deadline then
                                                        q.Timer.Dispose()
                                                        pending.Remove peer |> ignore
                                                        false
                                                    else
                                                        true
                                                | _ -> false)

                                        if resend then
                                            this.Wire(peer, hello) |> ignore),
                                    null,
                                    100,
                                    100
                                )

                            p.Timer <- timer
                            Choice2Of3 hello)

        match action with
        | Choice1Of3 sealedFrame -> this.Wire(peer, sealedFrame)
        | Choice2Of3 hello -> this.Wire(peer, hello)
        | Choice3Of3 result -> result

    member this.Close() =
        lock gate (fun () ->
            closed <- true

            for p in pending.Values do
                p.Timer.Dispose()

            pending.Clear())

        if not (isNull (box connection)) then
            connection.Dispose()

    interface IDisposable with
        member this.Dispose() = this.Close()

and private PendingHandshake =
    {
        Session: byte[]
        Seed: byte[]
        Body: byte[]
        Hello: byte[]
        Queue: ResizeArray<byte[]>
        mutable Timer: Timer
    }

/// The secure network's primitives from LawSpec.Runtime.Crypto (BouncyCastle
/// ML-DSA-65 and ML-KEM-768; SHA3, SHAKE256 and AES-256-GCM).
[<Sealed>]
type RuntimeNetworkCrypto() =
    interface INetworkCrypto with
        member _.MlDsaPublic seed = Crypto.mldsaPublic seed
        member _.MlDsaSign(seed, message) = Crypto.mldsaSign seed message

        member _.MlDsaVerify(publicKey, message, signature) =
            Crypto.mldsaVerify publicKey message signature

        member _.MlKemKeypair seed = Crypto.mlkemKeyPair seed

        member _.MlKemEncapsulate encapsulationKey =
            Crypto.mlkemEncapsulate encapsulationKey

        member _.MlKemDecapsulate(seed, ciphertext) = Crypto.mlkemDecapsulate seed ciphertext
        member _.Sha3_256 bytes = Crypto.sha3 bytes
        member _.Shake256(bytes, length) = Crypto.shake bytes length

        member _.AesGcmEncrypt(key, nonce, plaintext, associated) =
            Crypto.aes256GcmEncrypt key nonce plaintext associated

        member _.AesGcmDecrypt(key, nonce, sealedBytes, associated) =
            Crypto.aes256GcmDecrypt key nonce sealedBytes associated

/// The crypto primitives of the secure network: the runtime's own, unless
/// another implementation is installed.
module SecureNetwork =
    let mutable private installed: INetworkCrypto = RuntimeNetworkCrypto()

    /// Install other primitives (tests and alternative providers).
    [<CompiledName("Install")>]
    let install (crypto: INetworkCrypto) = installed <- crypto

    [<CompiledName("Crypto")>]
    let crypto () = installed
