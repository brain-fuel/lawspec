// User-owned LawSpec adapter: native code that gets lawspec.crypto's
// handlers as arguments.
package crypto

import "bytes"

// Fingerprint implements fingerprint :: (Bytes -> Bytes).
func Fingerprint(hash Hash, value0 []byte) []byte {
	return hash.Sha3(value0).Value[:8]
}

// RoundTrip implements roundTrip :: (Bytes -> Bool).
func RoundTrip(aead Aead, value0 []byte) bool {
	key := aead.AeadKey()
	label := []byte("round trip")
	opened := aead.Unseal(key, aead.Seal(key, value0, label), label)
	value, present := opened.Value()
	return present && bytes.Equal(value, value0)
}
