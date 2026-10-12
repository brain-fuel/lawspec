// Application code: the Signature and KeyExchange handlers bound in
// lawspec.json in place of the defaults. Each passes its operations on to
// the default handler and counts them.
package example

class CountingSigner extends lawspec.abilities.lawspec.Crypto.Signature {
  private val inner: lawspec.abilities.lawspec.Crypto.Signature = lawspec.Crypto.SignatureHandler()
  private val count = java.util.concurrent.atomic.AtomicInteger()

  override def signingKeyPair(): lawspec.data.SigningKeyPair = inner.signingKeyPair()

  override def sign(value0: lawspec.data.SigningKey, value1: scala.IArray[scala.Byte]): lawspec.data.SignatureBytes = {
    count.incrementAndGet()
    inner.sign(value0, value1)
  }

  override def verify(value0: lawspec.data.VerifyingKey, value1: scala.IArray[scala.Byte], value2: lawspec.data.SignatureBytes): scala.Boolean =
    inner.verify(value0, value1, value2)
}

class CountingExchange extends lawspec.abilities.lawspec.Crypto.KeyExchange {
  private val inner: lawspec.abilities.lawspec.Crypto.KeyExchange = lawspec.Crypto.KeyExchangeHandler()
  private val count = java.util.concurrent.atomic.AtomicInteger()

  override def exchangeKeyPair(): lawspec.data.ExchangeKeyPair = inner.exchangeKeyPair()

  override def encapsulate(value0: lawspec.data.ExchangePublicKey): lawspec.data.Encapsulated = {
    count.incrementAndGet()
    inner.encapsulate(value0)
  }

  override def decapsulate(value0: lawspec.data.ExchangeSecretKey, value1: lawspec.data.Ciphertext): lawspec.data.SharedSecret =
    inner.decapsulate(value0, value1)
}
