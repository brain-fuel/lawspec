/// NIST known-answer checks of the default crypto primitives, over the
/// vectors every target shares (runtime/defaults/vectors.txt, provenance in
/// docs/reference/language/cryptography.md). ref:DEC-tests-cite-requirements
module LawSpec.Testing.CryptoVectors

open System
open LawSpec.Runtime

let private fail (kind: string) (detail: string) : 'a = Fail.raiseWith "CryptoVectorFailed" (kind + ": " + detail)

let private hex (text: string) = if text = "-" then [||] else Convert.FromHexString text
let private digest (bytes: byte[]) = Convert.ToHexString(Crypto.sha3 bytes).ToLowerInvariant()
let private flip (bytes: byte[]) =
    let copy = Array.copy bytes
    copy.[0] <- copy.[0] ^^^ 1uy
    copy

let private same (kind: string) (what: string) (expected: byte[]) (actual: byte[]) =
    if expected <> actual then fail kind (what + " differs")

let private holds (kind: string) (what: string) (condition: bool) = if not condition then fail kind what

/// Check every vector of a kind in the vectors text.
[<CompiledName("Check")>]
let check (vectors: string) (kind: string) =
    let rows =
        vectors.Split('\n')
        |> Array.map (fun line -> line.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        |> Array.filter (fun fields -> fields.Length > 0 && fields.[0] = kind)
        |> Array.map (fun fields -> List.ofArray fields.[1..])
    if rows.Length = 0 then fail kind "no vectors"
    for row in rows do
        match kind, row with
        | "sha3-256", [ message; expected ] -> same kind "digest" (hex expected) (Crypto.sha3 (hex message))
        | "shake256", [ message; count; expected ] -> same kind "output" (hex expected) (Crypto.shake (hex message) (int count))
        | "aes-256-gcm", [ key; nonce; message; associated; ciphertext; tag ] ->
            let key, nonce, message, associated = hex key, hex nonce, hex message, hex associated
            let expected = Array.append (hex ciphertext) (hex tag)
            same kind "sealed" expected (Crypto.aes256GcmEncrypt key nonce message associated)
            holds kind "decrypts" (Crypto.aes256GcmDecrypt key nonce expected associated = Some message)
            holds kind "rejects a changed ciphertext" (Crypto.aes256GcmDecrypt key nonce (flip expected) associated = None)
        | "mlkem768-keygen", [ d; z; publicDigest; privateDigest ] ->
            let seed = hex (d + z)
            let publicKey, privateKey = Crypto.mlkemExpand seed
            holds kind "public key" (digest publicKey = publicDigest)
            holds kind "private key" (digest privateKey = privateDigest)
            holds kind "key pair" (Crypto.mlkemKeyPair seed = (publicKey, seed))
        | "mlkem768-encaps", [ publicKey; message; ciphertext; shared ] ->
            let c, s = Crypto.mlkemEncapsulateWith (hex publicKey) (hex message)
            same kind "ciphertext" (hex ciphertext) c
            same kind "shared secret" (hex shared) s
        | "mlkem768-decaps", [ privateKey; ciphertext; shared ] ->
            same kind "shared secret" (hex shared) (Crypto.mlkemDecapsulateExpanded (hex privateKey) (hex ciphertext))
        | "mlkem768-decaps-seed", [ seed; ciphertext; shared ] ->
            same kind "shared secret" (hex shared) (Crypto.mlkemDecapsulate (hex seed) (hex ciphertext))
        | "mldsa65-keygen", [ seed; publicDigest; privateDigest ] ->
            let publicKey, privateKey = Crypto.mldsaExpand (hex seed)
            holds kind "public key" (digest publicKey = publicDigest)
            holds kind "private key" (digest privateKey = privateDigest)
            same kind "public key of the seed" publicKey (Crypto.mldsaPublic (hex seed))
        | "mldsa65-verify", [ publicKey; message; context; signature; passed ] ->
            holds kind "verification" (Crypto.mldsaVerifyWith (hex publicKey) (hex message) (hex signature) (hex context) = (passed = "true"))
        | "mldsa65-sign-seed", [ seed; message; signature ] ->
            let seed, message = hex seed, hex message
            let signed = Crypto.mldsaSignWith seed message [||] true
            same kind "signature" (hex signature) signed
            let publicKey = Crypto.mldsaPublic seed
            holds kind "verifies" (Crypto.mldsaVerify publicKey message signed)
            holds kind "rejects a changed message" (not (Crypto.mldsaVerify publicKey (flip message) signed))
        | "slhdsa128f-keygen", [ s; p; x; publicHex; privateDigest ] ->
            let publicKey, privateKey = Crypto.slhKeyPairOf (hex (s + p + x))
            same kind "public key" (hex publicHex) publicKey
            holds kind "private key" (digest privateKey = privateDigest)
            let message = Text.Encoding.ASCII.GetBytes "LawSpec"
            let signature = Crypto.slhSign privateKey message
            holds kind "verifies" (Crypto.slhVerify publicKey message signature)
            holds kind "rejects a changed message" (not (Crypto.slhVerify publicKey (Text.Encoding.ASCII.GetBytes "LawSpeC") signature))
        | "slhdsa128f-verify", [ publicKey; message; context; signature; passed ] ->
            let publicKey, message, signature, context = hex publicKey, hex message, hex signature, hex context
            holds kind "verification" (Crypto.slhVerifyWith publicKey message signature context = (passed = "true"))
            holds kind "rejects a changed message" (not (Crypto.slhVerifyWith publicKey (flip message) signature context))
        | _ -> fail kind (sprintf "unexpected row of %d fields" row.Length)
