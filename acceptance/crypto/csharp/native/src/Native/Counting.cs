// Application code: the Signature and KeyExchange handlers bound in
// lawspec.edn in place of the defaults. Each passes its operations on to
// the default handler and counts them.
namespace Example.Counting;

using LawSpec.Abilities.LawspecCrypto;
using LawSpec.Data;

public sealed class CountingSigner : ISignature
{
    private readonly ISignature inner = LawSpec.DefaultHandlers.Signature();
    private int count;

    public SigningKeyPair SigningKeyPair() => inner.SigningKeyPair();

    public SignatureBytes Sign(SigningKey key, byte[] message)
    {
        count++;
        return inner.Sign(key, message);
    }

    public bool Verify(VerifyingKey key, byte[] message, SignatureBytes signature) =>
        inner.Verify(key, message, signature);
}

public sealed class CountingExchange : IKeyExchange
{
    private readonly IKeyExchange inner = LawSpec.DefaultHandlers.KeyExchange();
    private int count;

    public ExchangeKeyPair ExchangeKeyPair() => inner.ExchangeKeyPair();

    public Encapsulated Encapsulate(ExchangePublicKey key)
    {
        count++;
        return inner.Encapsulate(key);
    }

    public SharedSecret Decapsulate(ExchangeSecretKey key, Ciphertext ciphertext) =>
        inner.Decapsulate(key, ciphertext);
}
