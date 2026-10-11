// User-owned LawSpec adapter: native code that gets lawspec.crypto's
// handlers as arguments. ref:DEC-acceptance-with-mutants
module Example.Crypto

open System.Text
open LawSpec.Abilities.LawspecCrypto

let fingerprint (hash: IHash) (bytes: byte[]) : byte[] = (hash.Sha3 bytes).Value.[0..7]

let roundTrip (aead: IAead) (bytes: byte[]) : bool =
    let key = aead.AeadKey()
    let label = Encoding.UTF8.GetBytes "round trip"
    match aead.Unseal(key, aead.Seal(key, bytes, label), label) with
    | Some opened -> opened = bytes
    | None -> false
