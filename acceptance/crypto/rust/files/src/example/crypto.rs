// Scaffolded by LawSpec. User-owned; never overwritten.
// Native code that gets lawspec.crypto's handlers as arguments.
#![allow(unused_variables, unused_imports, non_snake_case)]
use crate::lawspec_runtime as ls;

// LawSpec: (Bytes -> Bytes)
pub fn fingerprint(hash: &dyn crate::lawspec_abilities::lawspec_crypto::Hash, value0: Vec<u8>) -> Vec<u8> {
    hash.sha3(value0).value[..8].to_vec()
}

// LawSpec: (Bytes -> Bool)
pub fn roundTrip(aead: &dyn crate::lawspec_abilities::lawspec_crypto::Aead, value0: Vec<u8>) -> bool {
    let key = aead.aeadKey();
    let label = b"round trip".to_vec();
    let sealed = aead.seal(key.clone(), value0.clone(), label.clone());
    aead.unseal(key, sealed, label) == Some(value0)
}
