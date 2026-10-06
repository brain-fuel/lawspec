# User-owned LawSpec adapter: native code that gets lawspec.crypto's
# handlers as arguments.


# LawSpec argument 0: Bytes
# LawSpec result: Bytes
def fingerprint(hash: "lawspec_abilities.lawspec.crypto.Hash", value0: bytes) -> bytes:
    return hash.sha3(value0).value[:8]


# LawSpec argument 0: Bytes
# LawSpec result: Bool
def roundTrip(aead: "lawspec_abilities.lawspec.crypto.Aead", value0: bytes) -> bool:
    key = aead.aeadKey()
    opened = aead.unseal(key, aead.seal(key, value0, b"round trip"), b"round trip")
    return getattr(opened, "value", None) == value0
