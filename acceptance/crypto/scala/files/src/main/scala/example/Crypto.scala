// User-owned LawSpec adapter: native code that gets lawspec.crypto's
// handlers as arguments.
package example

object Crypto {
  // (Bytes -> Bytes)
  def fingerprint(
    hash: lawspec.abilities.lawspec.Crypto.Hash,
    value0: scala.IArray[scala.Byte],
  ): scala.IArray[scala.Byte] = hash.sha3(value0).value.take(8)

  // (Bytes -> Bool)
  def roundTrip(
    aead: lawspec.abilities.lawspec.Crypto.Aead,
    value0: scala.IArray[scala.Byte],
  ): scala.Boolean = {
    val key = aead.aeadKey()
    val label = IArray.from("round trip".getBytes(java.nio.charset.StandardCharsets.UTF_8))
    aead.unseal(key, aead.seal(key, value0, label), label).exists(_.sameElements(value0))
  }
}
