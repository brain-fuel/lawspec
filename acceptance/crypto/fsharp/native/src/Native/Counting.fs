// Application code: the Signature and KeyExchange handlers bound in
// lawspec.json in place of the defaults. Each passes its operations on to
// the default handler and counts them.
namespace Example.Counting

open LawSpec.Abilities.LawspecCrypto

type CountingSigner() =
    let inner: ISignature = LawSpec.DefaultHandlers.signature ()
    let mutable count = 0
    interface ISignature with
        member _.SigningKeyPair() = inner.SigningKeyPair()
        member _.Sign(key, message) =
            count <- count + 1
            inner.Sign(key, message)
        member _.Verify(key, message, signature) =
            inner.Verify(key, message, signature)

type CountingExchange() =
    let inner: IKeyExchange = LawSpec.DefaultHandlers.keyExchange ()
    let mutable count = 0
    interface IKeyExchange with
        member _.ExchangeKeyPair() = inner.ExchangeKeyPair()
        member _.Encapsulate(key) =
            count <- count + 1
            inner.Encapsulate key
        member _.Decapsulate(key, ciphertext) =
            inner.Decapsulate(key, ciphertext)
