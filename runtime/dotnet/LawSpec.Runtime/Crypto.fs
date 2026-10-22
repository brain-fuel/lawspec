/// LawSpec's post-quantum crypto defaults on .NET: SHA3-256 and SHAKE256
/// (FIPS 202), ML-KEM-768 (FIPS 203), ML-DSA-65 (FIPS 204), SLH-DSA-SHAKE-128f
/// (FIPS 205) and AES-256-GCM (SP 800-38D). Keys are stored as their FIPS
/// key-generation seeds, as on every target, so the portable values are the
/// same. .NET 10's System.Security.Cryptography is used where the platform
/// supports it; BouncyCastle otherwise, and for the deterministic forms the
/// known-answer tests need. Both give the standards' bytes.
/// ref:DEC-typed-core-boundary ref:DEC-fsharp-runtime-from-scratch
module LawSpec.Runtime.Crypto

#nowarn "57"

open System
open System.Numerics
open System.Security.Cryptography
open Org.BouncyCastle.Crypto
open Org.BouncyCastle.Crypto.Digests
open Org.BouncyCastle.Crypto.Engines
open Org.BouncyCastle.Crypto.Generators
open Org.BouncyCastle.Crypto.Kems
open Org.BouncyCastle.Crypto.Modes
open Org.BouncyCastle.Crypto.Parameters
open Org.BouncyCastle.Crypto.Signers

let private fail code detail : 'a = Fail.raiseWith code detail

/// A SecureRandom that hands out fixed bytes in order: the deterministic
/// randomness a FIPS known-answer test supplies (an encapsulation's message,
/// an SLH-DSA key's seeds).
type private FixedRandom(bytes: byte[]) =
    inherit Org.BouncyCastle.Security.SecureRandom()
    let mutable position = 0
    let take (buffer: byte[]) start length =
        if position + length > bytes.Length then fail "FixedRandomExhausted" ""
        Array.blit bytes position buffer start length
        position <- position + length
    override _.NextBytes(buffer: byte[]) = take buffer 0 buffer.Length
    override _.NextBytes(buffer: byte[], start: int, length: int) = take buffer start length
    override _.NextBytes(buffer: Span<byte>) =
        if position + buffer.Length > bytes.Length then fail "FixedRandomExhausted" ""
        ReadOnlySpan<byte>(bytes, position, buffer.Length).CopyTo(buffer)
        position <- position + buffer.Length

let private secure = Org.BouncyCastle.Security.SecureRandom()

/// Fresh random bytes from the operating system.
[<CompiledName("RandomBytes")>]
let randomBytes (count: int) = RandomNumberGenerator.GetBytes(max 0 count)

// ---------------------------------------------------------------------------
// FIPS 202

/// SHA3-256 of a message.
[<CompiledName("Sha3")>]
let sha3 (message: byte[]) : byte[] =
    if SHA3_256.IsSupported then SHA3_256.HashData message
    else
        let digest = Sha3Digest(256)
        digest.BlockUpdate(message, 0, message.Length)
        let out = Array.zeroCreate 32
        digest.DoFinal(out, 0) |> ignore
        out

/// SHAKE256 of a message, a number of bytes long (none when it is not
/// positive).
[<CompiledName("Shake")>]
let shake (message: byte[]) (count: int) : byte[] =
    if count <= 0 then [||]
    elif Shake256.IsSupported then Shake256.HashData(message, count)
    else
        let digest = ShakeDigest(256)
        digest.BlockUpdate(message, 0, message.Length)
        let out = Array.zeroCreate count
        digest.OutputFinal(out, 0, count) |> ignore
        out

/// An AES-256-GCM key for a shared secret and a context.
[<CompiledName("DeriveAeadKey")>]
let deriveAeadKey (secret: byte[]) (context: byte[]) = shake (Array.append secret context) 32

// ---------------------------------------------------------------------------
// FIPS 203: ML-KEM-768, keys held as their 64-byte seed d || z

let private kem = MLKemParameters.ml_kem_768

/// The encapsulation key and the expanded decapsulation key of a seed.
[<CompiledName("MlKemExpand")>]
let mlkemExpand (seed: byte[]) : byte[] * byte[] =
    if seed.Length <> 64 then fail "InvalidMlKemSeed" ""
    if MLKem.IsSupported then
        use key = MLKem.ImportPrivateSeed(MLKemAlgorithm.MLKem768, seed)
        key.ExportEncapsulationKey(), key.ExportDecapsulationKey()
    else
        let key = MLKemPrivateKeyParameters.FromSeed(kem, seed, MLKemPrivateKeyParameters.Format.EncodingOnly)
        key.GetPublicKeyEncoded(), key.GetEncoded()

/// A key pair from a seed: the public key, and the seed it is kept as.
[<CompiledName("MlKemKeyPair")>]
let mlkemKeyPair (seed: byte[]) = fst (mlkemExpand seed), seed

let private bcEncapsulate (publicKey: byte[]) (random: Org.BouncyCastle.Security.SecureRandom) =
    if publicKey.Length <> 1184 then fail "InvalidMlKemPublicKey" ""
    let encapsulator = MLKemEncapsulator(kem)
    encapsulator.Init(ParametersWithRandom(MLKemPublicKeyParameters.FromEncoding(kem, publicKey), random))
    let ciphertext = Array.zeroCreate encapsulator.EncapsulationLength
    let shared = Array.zeroCreate encapsulator.SecretLength
    encapsulator.Encapsulate(ciphertext, 0, ciphertext.Length, shared, 0, shared.Length)
    ciphertext, shared

/// Encapsulate a fresh shared secret: the ciphertext and the secret.
[<CompiledName("MlKemEncapsulate")>]
let mlkemEncapsulate (publicKey: byte[]) : byte[] * byte[] =
    if MLKem.IsSupported then
        if publicKey.Length <> 1184 then fail "InvalidMlKemPublicKey" ""
        use key = MLKem.ImportEncapsulationKey(MLKemAlgorithm.MLKem768, publicKey)
        let mutable ciphertext = null
        let mutable shared = null
        key.Encapsulate(&ciphertext, &shared)
        ciphertext, shared
    else bcEncapsulate publicKey secure

/// FIPS 203's deterministic encapsulation with a given 32-byte message, for
/// known-answer tests only.
[<CompiledName("MlKemEncapsulateWith")>]
let mlkemEncapsulateWith (publicKey: byte[]) (message: byte[]) =
    if message.Length <> 32 then fail "InvalidMlKemMessage" ""
    bcEncapsulate publicKey (new FixedRandom(message))

/// Decapsulate with an expanded decapsulation key.
[<CompiledName("MlKemDecapsulateExpanded")>]
let mlkemDecapsulateExpanded (privateKey: byte[]) (ciphertext: byte[]) : byte[] =
    if MLKem.IsSupported then
        use key = MLKem.ImportDecapsulationKey(MLKemAlgorithm.MLKem768, privateKey)
        key.Decapsulate ciphertext
    else
        let decapsulator = MLKemDecapsulator(kem)
        decapsulator.Init(MLKemPrivateKeyParameters.FromEncoding(kem, privateKey))
        let shared = Array.zeroCreate decapsulator.SecretLength
        decapsulator.Decapsulate(ciphertext, 0, ciphertext.Length, shared, 0, shared.Length)
        shared

/// Decapsulate with a key kept as its seed.
[<CompiledName("MlKemDecapsulate")>]
let mlkemDecapsulate (seed: byte[]) (ciphertext: byte[]) = mlkemDecapsulateExpanded (snd (mlkemExpand seed)) ciphertext

// ---------------------------------------------------------------------------
// FIPS 204: ML-DSA-65, signing keys held as their 32-byte seed

let private dsa = MLDsaParameters.ml_dsa_65

/// The public key and the expanded private key of a seed.
[<CompiledName("MlDsaExpand")>]
let mldsaExpand (seed: byte[]) : byte[] * byte[] =
    if seed.Length <> 32 then fail "InvalidMlDsaSeed" ""
    if MLDsa.IsSupported then
        use key = MLDsa.ImportMLDsaPrivateSeed(MLDsaAlgorithm.MLDsa65, seed)
        key.ExportMLDsaPublicKey(), key.ExportMLDsaPrivateKey()
    else
        let key = MLDsaPrivateKeyParameters.FromSeed(dsa, seed, MLDsaPrivateKeyParameters.Format.EncodingOnly)
        key.GetPublicKeyEncoded(), key.GetEncoded()

/// The public key of a seed.
[<CompiledName("MlDsaPublic")>]
let mldsaPublic (seed: byte[]) = fst (mldsaExpand seed)

let private bcSign (deterministic: bool) (key: ICipherParameters) (message: byte[]) (context: byte[]) =
    let signer = MLDsaSigner(dsa, deterministic)
    let keyed = if deterministic then key else ParametersWithRandom(key, secure) :> ICipherParameters
    signer.Init(true, ParametersWithContext(keyed, context))
    signer.BlockUpdate(message, 0, message.Length)
    signer.GenerateSignature()

/// Sign with a context string; deterministic for known-answer tests, hedged
/// otherwise.
[<CompiledName("MlDsaSignWith")>]
let mldsaSignWith (seed: byte[]) (message: byte[]) (context: byte[]) (deterministic: bool) : byte[] =
    if seed.Length <> 32 || context.Length > 255 then fail "InvalidMlDsaSignature" ""
    if MLDsa.IsSupported && not deterministic then
        use key = MLDsa.ImportMLDsaPrivateSeed(MLDsaAlgorithm.MLDsa65, seed)
        key.SignData(message, context)
    else
        bcSign deterministic (MLDsaPrivateKeyParameters.FromSeed(dsa, seed)) message context

/// Sign a message (hedged, with no context).
[<CompiledName("MlDsaSign")>]
let mldsaSign (seed: byte[]) (message: byte[]) = mldsaSignWith seed message [||] false

/// Verify a signature with a context string; a malformed key or signature
/// does not verify.
[<CompiledName("MlDsaVerifyWith")>]
let mldsaVerifyWith (publicKey: byte[]) (message: byte[]) (signature: byte[]) (context: byte[]) : bool =
    if publicKey.Length <> 1952 || signature.Length <> 3309 || context.Length > 255 then false
    elif MLDsa.IsSupported then
        use key = MLDsa.ImportMLDsaPublicKey(MLDsaAlgorithm.MLDsa65, publicKey)
        key.VerifyData(message, signature, context)
    else
        let signer = MLDsaSigner(dsa, false)
        signer.Init(false, ParametersWithContext(MLDsaPublicKeyParameters.FromEncoding(dsa, publicKey), context))
        signer.BlockUpdate(message, 0, message.Length)
        signer.VerifySignature signature

[<CompiledName("MlDsaVerify")>]
let mldsaVerify (publicKey: byte[]) (message: byte[]) (signature: byte[]) = mldsaVerifyWith publicKey message signature [||]

// ---------------------------------------------------------------------------
// FIPS 205: SLH-DSA-SHAKE-128f, private keys of 64 bytes

let private slh = SlhDsaParameters.slh_dsa_shake_128f

let private slhGenerate (random: Org.BouncyCastle.Security.SecureRandom) =
    let generator = SlhDsaKeyPairGenerator()
    generator.Init(SlhDsaKeyGenerationParameters(random, slh))
    let pair = generator.GenerateKeyPair()
    (pair.Public :?> SlhDsaPublicKeyParameters).GetEncoded(), (pair.Private :?> SlhDsaPrivateKeyParameters).GetEncoded()

/// A fresh key pair: the public key and the private key.
[<CompiledName("SlhKeyPair")>]
let slhKeyPair () : byte[] * byte[] =
    if SlhDsa.IsSupported then
        use key = SlhDsa.GenerateKey(SlhDsaAlgorithm.SlhDsaShake128f)
        key.ExportSlhDsaPublicKey(), key.ExportSlhDsaPrivateKey()
    else slhGenerate secure

/// The key pair of the 48 bytes SK.seed || SK.prf || PK.seed (known-answer
/// tests only).
[<CompiledName("SlhKeyPairOf")>]
let slhKeyPairOf (seed: byte[]) =
    if seed.Length <> 48 then fail "InvalidSlhDsaSeed" ""
    slhGenerate (new FixedRandom(seed))

/// Sign with a context string.
[<CompiledName("SlhSignWith")>]
let slhSignWith (privateKey: byte[]) (message: byte[]) (context: byte[]) : byte[] =
    if privateKey.Length <> 64 || context.Length > 255 then fail "InvalidSlhDsaSignature" ""
    if SlhDsa.IsSupported then
        use key = SlhDsa.ImportSlhDsaPrivateKey(SlhDsaAlgorithm.SlhDsaShake128f, privateKey)
        key.SignData(message, context)
    else
        let signer = SlhDsaSigner(slh, false)
        signer.Init(true, ParametersWithContext(ParametersWithRandom(SlhDsaPrivateKeyParameters.FromEncoding(slh, privateKey), secure), context))
        signer.BlockUpdate(message, 0, message.Length)
        signer.GenerateSignature()

[<CompiledName("SlhSign")>]
let slhSign (privateKey: byte[]) (message: byte[]) = slhSignWith privateKey message [||]

/// Verify with a context string; a malformed key or signature does not verify.
[<CompiledName("SlhVerifyWith")>]
let slhVerifyWith (publicKey: byte[]) (message: byte[]) (signature: byte[]) (context: byte[]) : bool =
    if publicKey.Length <> 32 || signature.Length <> 17088 || context.Length > 255 then false
    elif SlhDsa.IsSupported then
        use key = SlhDsa.ImportSlhDsaPublicKey(SlhDsaAlgorithm.SlhDsaShake128f, publicKey)
        key.VerifyData(message, signature, context)
    else
        let signer = SlhDsaSigner(slh, false)
        signer.Init(false, ParametersWithContext(SlhDsaPublicKeyParameters.FromEncoding(slh, publicKey), context))
        signer.BlockUpdate(message, 0, message.Length)
        signer.VerifySignature signature

[<CompiledName("SlhVerify")>]
let slhVerify (publicKey: byte[]) (message: byte[]) (signature: byte[]) = slhVerifyWith publicKey message signature [||]

// ---------------------------------------------------------------------------
// SP 800-38D: AES-256-GCM with a 96-bit nonce and a 128-bit tag

/// The ciphertext followed by its tag.
[<CompiledName("Aes256GcmEncrypt")>]
let aes256GcmEncrypt (key: byte[]) (nonce: byte[]) (message: byte[]) (associated: byte[]) : byte[] =
    if key.Length <> 32 || nonce.Length <> 12 then fail "InvalidAeadKey" ""
    if AesGcm.IsSupported then
        use aes = new AesGcm(key, 16)
        let ciphertext = Array.zeroCreate message.Length
        let tag = Array.zeroCreate 16
        aes.Encrypt(nonce, message, ciphertext, tag, associated)
        Array.append ciphertext tag
    else
        let cipher = GcmBlockCipher(AesEngine())
        cipher.Init(true, AeadParameters(KeyParameter(key), 128, nonce, associated))
        let out = Array.zeroCreate (cipher.GetOutputSize message.Length)
        let n = cipher.ProcessBytes(message, 0, message.Length, out, 0)
        cipher.DoFinal(out, n) |> ignore
        out

/// The plaintext, or None when the tag does not verify.
[<CompiledName("Aes256GcmDecrypt")>]
let aes256GcmDecrypt (key: byte[]) (nonce: byte[]) (sealedBytes: byte[]) (associated: byte[]) : byte[] option =
    if key.Length <> 32 || nonce.Length <> 12 || sealedBytes.Length < 16 then None
    elif AesGcm.IsSupported then
        use aes = new AesGcm(key, 16)
        let size = sealedBytes.Length - 16
        let plaintext = Array.zeroCreate size
        try
            aes.Decrypt(nonce, sealedBytes.[.. size - 1], sealedBytes.[size ..], plaintext, associated)
            Some plaintext
        with :? CryptographicException -> None
    else
        let cipher = GcmBlockCipher(AesEngine())
        cipher.Init(false, AeadParameters(KeyParameter(key), 128, nonce, associated))
        let out = Array.zeroCreate (cipher.GetOutputSize sealedBytes.Length)
        try
            let n = cipher.ProcessBytes(sealedBytes, 0, sealedBytes.Length, out, 0)
            cipher.DoFinal(out, n) |> ignore
            Some out
        with :? InvalidCipherTextException -> None

/// A fresh nonce, then the sealed message.
[<CompiledName("Seal")>]
let seal (key: byte[]) (message: byte[]) (associated: byte[]) =
    let nonce = randomBytes 12
    Array.append nonce (aes256GcmEncrypt key nonce message associated)

/// Open what seal made, or None.
[<CompiledName("Unseal")>]
let unseal (key: byte[]) (sealedBytes: byte[]) (associated: byte[]) =
    if sealedBytes.Length < 12 then None
    else aes256GcmDecrypt key sealedBytes.[.. 11] sealedBytes.[12 ..] associated

// ---------------------------------------------------------------------------
// The abilities' default handlers, over portable values

let private tag name = "lawspec.crypto::type::" + name + "::" + name
let private wrap name (bytes: byte[]) = Data(tag name, [ Bytes bytes ])
let private pair name first second = Data(tag name, [ first; second ])

let private unwrap name (value: Value) =
    match value with
    | Data(t, [ Bytes b ]) when t = tag name -> b
    | _ -> fail "InvalidCryptoValue" name

let private bytes (value: Value) =
    match value with
    | Bytes b -> b
    | _ -> fail "BytesRequired" ""

let private signatureHandler (make: unit -> byte[] * byte[]) sign verify =
    Effects.stateless
        [ "signingKeyPair",
          (fun _ _ ->
              let publicKey, secret = make ()
              pair "SigningKeyPair" (wrap "VerifyingKey" publicKey) (wrap "SigningKey" secret))
          "sign", (fun _ args -> match args with
                                 | [ secret; message ] -> wrap "SignatureBytes" (sign (unwrap "SigningKey" secret) (bytes message))
                                 | _ -> fail "InvalidArguments" "sign")
          "verify", (fun _ args -> match args with
                                   | [ publicKey; message; signature ] ->
                                       Bool(verify (unwrap "VerifyingKey" publicKey) (bytes message) (unwrap "SignatureBytes" signature))
                                   | _ -> fail "InvalidArguments" "verify") ]

/// The SLH-DSA-SHAKE-128f handler of Signature: stateless hash-based
/// signatures, for programs that choose them over ML-DSA.
[<CompiledName("SlhDsaSignatureHandler")>]
let slhDsaSignatureHandler () = signatureHandler slhKeyPair slhSign slhVerify

/// The default handler of a lawspec.crypto ability.
[<CompiledName("Handler")>]
let handler (key: string) : Effects.Handler =
    match key with
    | "lawspec.crypto::ability::Hash" ->
        Effects.stateless
            [ "sha3", (fun _ args -> wrap "Digest" (sha3 (bytes (List.head args))))
              "shake",
              (fun _ args ->
                  match args with
                  | [ message; Int count ] -> Bytes(shake (bytes message) (if count > BigInteger(Int32.MaxValue) then Int32.MaxValue else int count))
                  | _ -> fail "InvalidArguments" "shake") ]
    | "lawspec.crypto::ability::KeyExchange" ->
        Effects.stateless
            [ "exchangeKeyPair",
              (fun _ _ ->
                  let publicKey, secret = mlkemKeyPair (randomBytes 64)
                  pair "ExchangeKeyPair" (wrap "ExchangePublicKey" publicKey) (wrap "ExchangeSecretKey" secret))
              "encapsulate",
              (fun _ args ->
                  let ciphertext, shared = mlkemEncapsulate (unwrap "ExchangePublicKey" (List.head args))
                  pair "Encapsulated" (wrap "Ciphertext" ciphertext) (wrap "SharedSecret" shared))
              "decapsulate",
              (fun _ args ->
                  match args with
                  | [ secret; ciphertext ] ->
                      wrap "SharedSecret" (mlkemDecapsulate (unwrap "ExchangeSecretKey" secret) (unwrap "Ciphertext" ciphertext))
                  | _ -> fail "InvalidArguments" "decapsulate") ]
    | "lawspec.crypto::ability::Signature" ->
        signatureHandler (fun () -> let seed = randomBytes 32 in mldsaPublic seed, seed) mldsaSign mldsaVerify
    | "lawspec.crypto::ability::Aead" ->
        Effects.stateless
            [ "aeadKey", (fun _ _ -> wrap "AeadKey" (randomBytes 32))
              "deriveAeadKey",
              (fun _ args ->
                  match args with
                  | [ secret; context ] -> wrap "AeadKey" (deriveAeadKey (unwrap "SharedSecret" secret) (bytes context))
                  | _ -> fail "InvalidArguments" "deriveAeadKey")
              "seal",
              (fun _ args ->
                  match args with
                  | [ key; message; associated ] -> wrap "Sealed" (seal (unwrap "AeadKey" key) (bytes message) (bytes associated))
                  | _ -> fail "InvalidArguments" "seal")
              "unseal",
              (fun _ args ->
                  match args with
                  | [ key; sealedValue; associated ] ->
                      match unseal (unwrap "AeadKey" key) (unwrap "Sealed" sealedValue) (bytes associated) with
                      | Some message -> Data("Maybe::Present", [ Bytes message ])
                      | None -> Data("Maybe::Absent", [])
                  | _ -> fail "InvalidArguments" "unseal") ]
    | _ -> fail "UnknownDefaultHandler" key

/// Make Defaults.handler answer the lawspec.crypto abilities. The generated
/// schema module of a program that uses lawspec.crypto calls this once.
[<CompiledName("Install")>]
let install () = Defaults.cryptoHandler <- handler
