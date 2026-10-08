import gleam/bit_array
import gleam/option.{Some}
import lawspec/abilities/lawspec/crypto
import lawspec/data

pub fn fingerprint(hash: crypto.Hash, bytes: BitArray) -> BitArray {
  let data.Digest(digest) = crypto.hash_sha3(hash, bytes)
  let assert Ok(prefix) = bit_array.slice(digest, 0, 8)
  prefix
}

pub fn round_trip(aead: crypto.Aead, message: BitArray) -> Bool {
  let key = crypto.aead_aead_key(aead)
  let associated = <<"round trip":utf8>>
  crypto.aead_unseal(aead, key, crypto.aead_seal(aead, key, message, associated), associated) == Some(message)
}
