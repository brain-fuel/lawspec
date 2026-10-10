/// The secure transport's version 1 records ("LS" 1): a node's ML-DSA-65
/// identity, the signed hello and welcome of the ML-KEM-768 handshake, the
/// session key derived with SHAKE256, and AES-256-GCM sealed frames. The
/// bytes are the same as every other target's, so nodes interoperate.
/// ref:DEC-distribution-canonical-wire ref:DEC-typed-core-boundary
module LawSpec.Runtime.NetworkCrypto

open System.Text

/// A node's identity: its signing seed and public key.
type Identity =
    private { Seed: byte[]; PublicKey: byte[] }
    member this.Public = this.PublicKey

let private fail code : 'a = Fail.raiseWith code ""

/// The identity of a 32-byte seed.
[<CompiledName("Identity")>]
let identity (seed: byte[]) =
    if isNull seed || seed.Length <> 32 then fail "InvalidNodeIdentity"
    { Seed = Array.copy seed; PublicKey = Crypto.mldsaPublic seed }

[<CompiledName("Public")>]
let publicKey (identity: Identity) = identity.PublicKey

/// The lowercase hex SHA3-256 of a node's public key.
[<CompiledName("Fingerprint")>]
let fingerprint (identity: Identity) = (System.Convert.ToHexString(Crypto.sha3 identity.PublicKey)).ToLowerInvariant()

[<CompiledName("Sign")>]
let sign (identity: Identity) (bytes: byte[]) = Crypto.mldsaSign identity.Seed bytes

[<CompiledName("Verify")>]
let verify (publicKey: byte[]) (bytes: byte[]) (signature: byte[]) = Crypto.mldsaVerify publicKey bytes signature

let private bytesType = Descriptors.Forms [ Descriptors.Atom "bytes" ]

/// Byte strings as consecutive length-prefixed wire fields.
[<CompiledName("Fields")>]
let fields (values: byte[] list) : byte[] =
    values |> List.map (fun v -> Descriptors.encode bytesType (Bytes v) Map.empty) |> Array.concat

let private readFields (count: int) (bytes: byte[]) (start: int) =
    let mutable position = start
    let values =
        [ for _ in 1 .. count ->
              match Descriptors.decodePrefix bytesType bytes position Map.empty with
              | Bytes b, next ->
                  position <- next
                  b
              | _ -> fail "InvalidSecureRecord" ]
    values, position

/// A handshake hello: session, address, public key and KEM public key.
[<CompiledName("Hello")>]
let hello (session: byte[]) (address: byte[]) (publicKey: byte[]) (kem: byte[]) = fields [ session; address; publicKey; kem ]

/// A handshake welcome, bound to the hello it answers.
[<CompiledName("Welcome")>]
let welcome (session: byte[]) (address: byte[]) (publicKey: byte[]) (ciphertext: byte[]) (helloBytes: byte[]) =
    fields [ session; address; publicKey; ciphertext; Crypto.sha3 helloBytes ]

/// The session key of a shared secret and the handshake that agreed it.
[<CompiledName("Key")>]
let key (shared: byte[]) (helloBytes: byte[]) (welcomeBytes: byte[]) =
    Crypto.shake (Array.concat [ shared; Encoding.ASCII.GetBytes "lawspec-session-v1"; Crypto.sha3 helloBytes; Crypto.sha3 welcomeBytes ]) 32

/// A signed handshake record of a kind (1 hello, 2 welcome).
[<CompiledName("Record")>]
let record (kind: byte) (body: byte[]) (signature: byte[]) =
    Array.concat [ [| byte 'L'; byte 'S'; 1uy; kind |]; body; fields [ signature ] ]

/// A record as read off the wire.
type Read =
    /// A hello (1) or welcome (2): its fields, the signed body and the signature.
    | Handshake of kind: int * values: byte[] list * body: byte[] * signature: byte[]
    /// A sealed frame: session, direction and sealed bytes.
    | Frame of session: byte[] * direction: byte * sealedBytes: byte[]

/// Read a version 1 record.
[<CompiledName("Read")>]
let read (bytes: byte[]) : Read =
    if bytes.Length < 4 || bytes.[0] <> byte 'L' || bytes.[1] <> byte 'S' || bytes.[2] <> 1uy then fail "InvalidSecureRecord"
    match bytes.[3] with
    | 1uy | 2uy as kind ->
        let count = if kind = 1uy then 4 else 5
        let values, bodyEnd = readFields count bytes 4
        let signature, finish = readFields 1 bytes bodyEnd
        if finish <> bytes.Length then fail "InvalidSecureRecord"
        Handshake(int kind, values, bytes.[4 .. bodyEnd - 1], List.head signature)
    | 3uy ->
        let session, next = readFields 1 bytes 4
        if next >= bytes.Length then fail "InvalidSecureRecord"
        let direction = bytes.[next]
        let sealedField, finish = readFields 1 bytes (next + 1)
        if finish <> bytes.Length then fail "InvalidSecureRecord"
        Frame(List.head session, direction, List.head sealedField)
    | _ -> fail "InvalidSecureRecord"

let private associated (session: byte[]) (direction: byte) =
    Array.concat [ Encoding.ASCII.GetBytes "lawspec-frame-v1"; session; [| direction |] ]

/// A frame sealed with a given nonce.
[<CompiledName("SealWith")>]
let sealWith (key: byte[]) (session: byte[]) (direction: byte) (frame: byte[]) (nonce: byte[]) =
    let sealedBytes = Array.append nonce (Crypto.aes256GcmEncrypt key nonce frame (associated session direction))
    Array.concat [ [| byte 'L'; byte 'S'; 1uy; 3uy |]; fields [ session ]; [| direction |]; fields [ sealedBytes ] ]

/// A frame sealed with a fresh nonce.
[<CompiledName("Seal")>]
let seal (key: byte[]) (session: byte[]) (direction: byte) (frame: byte[]) = sealWith key session direction frame (Crypto.randomBytes 12)

/// Open a sealed frame's bytes, or None.
[<CompiledName("Open")>]
let openFrame (key: byte[]) (session: byte[]) (direction: byte) (sealedBytes: byte[]) =
    Crypto.unseal key sealedBytes (associated session direction)
