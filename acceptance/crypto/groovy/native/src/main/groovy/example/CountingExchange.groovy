// Application code: the KeyExchange handler bound in lawspec.json in place
// of the default. It passes its operations on to the default and counts them.
package example

@groovy.transform.CompileStatic
final class CountingExchange implements lawspec.abilities.lawspec.Crypto.KeyExchange {
  private final lawspec.abilities.lawspec.Crypto.KeyExchange inner = new lawspec.Crypto.KeyExchangeHandler()
  private int count

  @Override
  lawspec.data.ExchangeKeyPair exchangeKeyPair() {
    return inner.exchangeKeyPair()
  }

  @Override
  lawspec.data.Encapsulated encapsulate(lawspec.data.ExchangePublicKey value0) {
    count++
    return inner.encapsulate(value0)
  }

  @Override
  lawspec.data.SharedSecret decapsulate(lawspec.data.ExchangeSecretKey value0, lawspec.data.Ciphertext value1) {
    return inner.decapsulate(value0, value1)
  }
}
