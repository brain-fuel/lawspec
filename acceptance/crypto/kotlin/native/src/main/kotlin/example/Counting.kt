// Application code: the Signature and KeyExchange handlers bound in
// lawspec.json in place of the defaults. Each passes its operations on to
// the default handler and counts them.
package example

class CountingSigner : lawspec.abilities.lawspec.Crypto.Signature {
    private val inner: lawspec.abilities.lawspec.Crypto.Signature = lawspec.Crypto.SignatureHandler()
    private var count = 0

    override fun signingKeyPair(): lawspec.data.SigningKeyPair = inner.signingKeyPair()

    override fun sign(value0: lawspec.data.SigningKey, value1: kotlin.ByteArray): lawspec.data.SignatureBytes {
        count++
        return inner.sign(value0, value1)
    }

    override fun verify(value0: lawspec.data.VerifyingKey, value1: kotlin.ByteArray, value2: lawspec.data.SignatureBytes): kotlin.Boolean {
        return inner.verify(value0, value1, value2)
    }
}

class CountingExchange : lawspec.abilities.lawspec.Crypto.KeyExchange {
    private val inner: lawspec.abilities.lawspec.Crypto.KeyExchange = lawspec.Crypto.KeyExchangeHandler()
    private var count = 0

    override fun exchangeKeyPair(): lawspec.data.ExchangeKeyPair = inner.exchangeKeyPair()

    override fun encapsulate(value0: lawspec.data.ExchangePublicKey): lawspec.data.Encapsulated {
        count++
        return inner.encapsulate(value0)
    }

    override fun decapsulate(value0: lawspec.data.ExchangeSecretKey, value1: lawspec.data.Ciphertext): lawspec.data.SharedSecret {
        return inner.decapsulate(value0, value1)
    }
}
