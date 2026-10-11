// User-owned LawSpec adapter: native code that gets lawspec.crypto's
// handlers as arguments. ref:DEC-acceptance-with-mutants
namespace Example;

using System.Linq;
using System.Text;
using LawSpec.Abilities.LawspecCrypto;

public static class Crypto
{
    public static byte[] Fingerprint(IHash hash, byte[] bytes) => hash.Sha3(bytes).Value[..8];

    public static bool RoundTrip(IAead aead, byte[] bytes)
    {
        var key = aead.AeadKey();
        var label = Encoding.UTF8.GetBytes("round trip");
        var opened = aead.Unseal(key, aead.Seal(key, bytes, label), label);
        return opened != null && opened.Value.SequenceEqual(bytes);
    }
}
