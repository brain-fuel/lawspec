// Application code: the Signature and KeyExchange handlers bound in
// lawspec.edn in place of the defaults. Each passes its operations on to
// the default handler and counts them.
import LawSpecRuntime

extension Example {
    public enum Counting {
        public final class CountingSigner: LawSpec.Abilities.LawspecCrypto.Signature {
            let inner: any LawSpec.Abilities.LawspecCrypto.Signature = LawSpec.DefaultHandlers.signature()
            var count = 0

            public init() {}

            public func signingKeyPair() -> SigningKeyPair { inner.signingKeyPair() }

            public func sign(_ key: SigningKey, _ message: [UInt8]) -> SignatureBytes {
                count += 1
                return inner.sign(key, message)
            }

            public func verify(_ key: VerifyingKey, _ message: [UInt8], _ signature: SignatureBytes) -> Bool {
                inner.verify(key, message, signature)
            }
        }

        public final class CountingExchange: LawSpec.Abilities.LawspecCrypto.KeyExchange {
            let inner: any LawSpec.Abilities.LawspecCrypto.KeyExchange = LawSpec.DefaultHandlers.keyExchange()
            var count = 0

            public init() {}

            public func exchangeKeyPair() -> ExchangeKeyPair { inner.exchangeKeyPair() }

            public func encapsulate(_ key: ExchangePublicKey) -> Encapsulated {
                count += 1
                return inner.encapsulate(key)
            }

            public func decapsulate(_ key: ExchangeSecretKey, _ ciphertext: Ciphertext) -> SharedSecret {
                inner.decapsulate(key, ciphertext)
            }
        }
    }
}
