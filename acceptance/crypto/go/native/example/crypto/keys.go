// Application code: the Signature and KeyExchange handlers bound in
// lawspec.json in place of the defaults. Each passes its operations on to
// the default handler and counts them. Each Go package has its own
// abilities, so each that uses them has this file.
package crypto

// CountingSigner passes its operations on to the default Signature handler.
type CountingSigner struct {
	inner Signature
	count int
}

// NewCountingSigner makes the bound Signature handler.
func NewCountingSigner() Signature {
	return &CountingSigner{inner: NewSignatureHandler()}
}

func (signer *CountingSigner) SigningKeyPair() SigningKeyPair {
	return signer.inner.SigningKeyPair()
}

func (signer *CountingSigner) Sign(value0 SigningKey, value1 []byte) SignatureBytes {
	signer.count++
	return signer.inner.Sign(value0, value1)
}

func (signer *CountingSigner) Verify(value0 VerifyingKey, value1 []byte, value2 SignatureBytes) bool {
	return signer.inner.Verify(value0, value1, value2)
}

// CountingExchange passes its operations on to the default KeyExchange handler.
type CountingExchange struct {
	inner KeyExchange
	count int
}

// NewCountingExchange makes the bound KeyExchange handler.
func NewCountingExchange() KeyExchange {
	return &CountingExchange{inner: NewKeyExchangeHandler()}
}

func (exchange *CountingExchange) ExchangeKeyPair() ExchangeKeyPair {
	return exchange.inner.ExchangeKeyPair()
}

func (exchange *CountingExchange) Encapsulate(value0 ExchangePublicKey) Encapsulated {
	exchange.count++
	return exchange.inner.Encapsulate(value0)
}

func (exchange *CountingExchange) Decapsulate(value0 ExchangeSecretKey, value1 Ciphertext) SharedSecret {
	return exchange.inner.Decapsulate(value0, value1)
}
