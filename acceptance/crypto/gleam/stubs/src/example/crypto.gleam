// User-owned LawSpec adapter. Implement these functions.

import lawspec/abilities/lawspec/crypto as abilities_lawspec_crypto

pub fn fingerprint(
  _hash_handler: abilities_lawspec_crypto.Hash,
  _bytes: BitArray,
) -> BitArray {
  panic as "Not implemented: example.crypto::fingerprint"
}

pub fn round_trip(
  _aead_handler: abilities_lawspec_crypto.Aead,
  _bytes: BitArray,
) -> Bool {
  panic as "Not implemented: example.crypto::roundTrip"
}
