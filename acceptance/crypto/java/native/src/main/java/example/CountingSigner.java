// Application code: the Signature handler bound in lawspec.json in place of
// the default. It passes its operations on to the default and counts them.
package example;

public final class CountingSigner implements lawspec.abilities.lawspec.Crypto.Signature {
  private final lawspec.abilities.lawspec.Crypto.Signature inner = new lawspec.Crypto.SignatureHandler();
  private int count;

  @Override
  public lawspec.data.SigningKeyPair signingKeyPair() {
    return inner.signingKeyPair();
  }

  @Override
  public lawspec.data.SignatureBytes sign(lawspec.data.SigningKey value0, byte[] value1) {
    count++;
    return inner.sign(value0, value1);
  }

  @Override
  public java.lang.Boolean verify(lawspec.data.VerifyingKey value0, byte[] value1, lawspec.data.SignatureBytes value2) {
    return inner.verify(value0, value1, value2);
  }
}
