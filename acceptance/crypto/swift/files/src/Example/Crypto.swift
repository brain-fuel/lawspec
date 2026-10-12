// User-owned LawSpec adapter: native code that gets lawspec.crypto's
// handlers as arguments. ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Crypto {
    static func fingerprint(_ hash: any LawSpec.Abilities.LawspecCrypto.Hash, _ bytes: [UInt8]) -> [UInt8] {
        Array(hash.sha3(bytes).value[0..<8])
    }

    static func roundTrip(_ aead: any LawSpec.Abilities.LawspecCrypto.Aead, _ bytes: [UInt8]) -> Bool {
        let key = aead.aeadKey()
        let label = Array("round trip".utf8)
        guard let opened = aead.unseal(key, aead.seal(key, bytes, label), label) else { return false }
        return opened == bytes
    }
}
