// User-owned LawSpec adapter. Implement these functions.

import lawspec/abilities/lawspec/crypto as abilities_lawspec_crypto

pub fn fingerprint(_handler0: abilities_lawspec_crypto.Hash, _argument0: BitArray) -> BitArray {
  panic as "Not implemented: example.crypto::fingerprint"
}

pub fn round_trip(_handler0: abilities_lawspec_crypto.Aead, _argument0: BitArray) -> Bool {
  panic as "Not implemented: example.crypto::roundTrip"
}
