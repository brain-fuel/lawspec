// Application code: the Signature and KeyExchange handlers bound in
// lawspec.json in place of the defaults. Each passes its operations on to
// the default handler and counts them.
use crate::lawspec_abilities::lawspec_crypto::{KeyExchange, Signature};
use crate::lawspec_data::*;

pub struct CountingSigner {
    inner: crate::lawspec_crypto::SignatureHandler,
    count: std::sync::atomic::AtomicUsize,
}

/// Makes the bound Signature handler.
pub fn counting_signer() -> CountingSigner {
    CountingSigner { inner: crate::lawspec_crypto::SignatureHandler, count: Default::default() }
}

impl Signature for CountingSigner {
    fn signingKeyPair(&self) -> SigningKeyPair {
        self.inner.signingKeyPair()
    }

    fn sign(&self, value0: SigningKey, value1: Vec<u8>) -> SignatureBytes {
        self.count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.inner.sign(value0, value1)
    }

    fn verify(&self, value0: VerifyingKey, value1: Vec<u8>, value2: SignatureBytes) -> bool {
        self.inner.verify(value0, value1, value2)
    }
}

pub struct CountingExchange {
    inner: crate::lawspec_crypto::KeyExchangeHandler,
    count: std::sync::atomic::AtomicUsize,
}

/// Makes the bound KeyExchange handler.
pub fn counting_exchange() -> CountingExchange {
    CountingExchange { inner: crate::lawspec_crypto::KeyExchangeHandler, count: Default::default() }
}

impl KeyExchange for CountingExchange {
    fn exchangeKeyPair(&self) -> ExchangeKeyPair {
        self.inner.exchangeKeyPair()
    }

    fn encapsulate(&self, value0: ExchangePublicKey) -> Encapsulated {
        self.count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.inner.encapsulate(value0)
    }

    fn decapsulate(&self, value0: ExchangeSecretKey, value1: Ciphertext) -> SharedSecret {
        self.inner.decapsulate(value0, value1)
    }
}
