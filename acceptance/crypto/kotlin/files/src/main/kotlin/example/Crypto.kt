// User-owned LawSpec adapter: native code that gets lawspec.crypto's
// handlers as arguments.
package example

import lawspec.runtime.LawSpecRuntime

object Crypto {
    // (Bytes -> Bytes)
    fun fingerprint(
        hash: lawspec.abilities.lawspec.Crypto.Hash,
        value0: kotlin.ByteArray,
    ): kotlin.ByteArray = hash.sha3(value0).value.copyOf(8)

    // (Bytes -> Bool)
    fun roundTrip(
        aead: lawspec.abilities.lawspec.Crypto.Aead,
        value0: kotlin.ByteArray,
    ): kotlin.Boolean {
        val key = aead.aeadKey()
        val label = "round trip".toByteArray()
        val opened = aead.unseal(key, aead.seal(key, value0, label), label)
        return opened is LawSpecRuntime.Just<*> && (opened.value() as ByteArray).contentEquals(value0)
    }
}
