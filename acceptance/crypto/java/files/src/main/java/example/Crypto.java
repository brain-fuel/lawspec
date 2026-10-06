// User-owned LawSpec adapter: native code that gets lawspec.crypto's
// handlers as arguments.
package example;

public final class Crypto {
  // (Bytes -> Bytes)
  public static byte[] fingerprint(lawspec.abilities.lawspec.Crypto.Hash hash, byte[] value0) {
    return java.util.Arrays.copyOf(hash.sha3(value0).value(), 8);
  }

  // (Bytes -> Bool)
  public static boolean roundTrip(lawspec.abilities.lawspec.Crypto.Aead aead, byte[] value0) {
    var key = aead.aeadKey();
    byte[] label = "round trip".getBytes(java.nio.charset.StandardCharsets.UTF_8);
    var opened = aead.unseal(key, aead.seal(key, value0, label), label);
    return opened instanceof lawspec.runtime.LawSpecRuntime.Just<byte[]> just && java.util.Arrays.equals(just.value(), value0);
  }
}
