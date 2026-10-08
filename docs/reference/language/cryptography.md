---
id: lawspec.reference.language.cryptography
kind: reference
title: Cryptography
---
# Cryptography

`lawspec.crypto` is post-quantum by default: key exchange with ML-KEM-768,
signatures with ML-DSA-65, hashing with SHA3-256 and SHAKE256, and
authenticated encryption with AES-256-GCM. Each is an ability with laws, and
each has a default handler on every target, checked against NIST's
known-answer vectors. It is one of the [built-in abilities](builtins.md).

```lawspec
unit guide.handshake

import lawspec.crypto (ExchangeKeyPair, ExchangePublicKey, Encapsulated, SigningKeyPair)

-- The server signs its exchange key; the client checks the signature,
-- encapsulates a secret to the key, and both sides derive the same AEAD key.
definition handshake (message :: Bytes) (context :: Bytes) :: Maybe Bytes uses KeyExchange, Signature, Aead is
  match signingKeyPair with
  | SigningKeyPair verifying signing ->
      (match exchangeKeyPair with
       | ExchangeKeyPair public secret ->
           (let offer = sign signing (valueOfExchangePublicKey public) in
            if verify verifying (valueOfExchangePublicKey public) offer then
              (match encapsulate public with
               | Encapsulated sent shared ->
                   (let client = deriveAeadKey shared context in
                    let server = deriveAeadKey (decapsulate secret sent) context in
                    unseal server (seal client message context) context)
               end)
            else Nothing)
       end)
  end
end

law `a handshake carries the message` is
  definition is `for all` (message :: Bytes) (context :: Bytes) . handshake message context = Just message end
end
```

## Keys and messages

Keys, ciphertexts and signatures are opaque wrappers over `Bytes`. Their
bytes are the standards' encodings, so they cross between targets and
programs:

| Type | Bytes |
| --- | --- |
| `Digest` | a SHA3-256 digest, 32 bytes |
| `ExchangePublicKey` | an ML-KEM-768 encapsulation key, 1184 bytes (FIPS 203) |
| `ExchangeSecretKey` | its seed, `d` then `z`, 64 bytes (FIPS 203, `ML-KEM.KeyGen_internal`) |
| `Ciphertext` | an ML-KEM-768 ciphertext, 1088 bytes |
| `SharedSecret` | 32 bytes |
| `VerifyingKey` | an ML-DSA-65 public key, 1952 bytes (FIPS 204) |
| `SigningKey` | its seed `xi`, 32 bytes (FIPS 204, `ML-DSA.KeyGen_internal`) |
| `SignatureBytes` | an ML-DSA-65 signature, 3309 bytes |
| `AeadKey` | an AES-256 key, 32 bytes |
| `Sealed` | a 12-byte nonce, the ciphertext, then a 16-byte tag |

A secret key is kept as its seed, the most compact form, from which every
library makes the key. `ExchangeKeyPair`, `Encapsulated` and `SigningKeyPair`
pair them up.

## Hash

```lawspec fragment
ability Hash is
  sha3 :: Bytes -> Digest
  shake :: Bytes -> Int32 -> Bytes
end
```

`sha3 m` is SHA3-256 and `shake m n` the first `n` bytes of SHAKE256, both
from FIPS 202. Laws: a digest is 32 bytes, a message has one digest,
different messages have different digests, and `shake` gives as many bytes
as asked.

## KeyExchange

```lawspec fragment
ability KeyExchange is
  exchangeKeyPair :: ExchangeKeyPair
  encapsulate :: ExchangePublicKey -> Encapsulated
  decapsulate :: ExchangeSecretKey -> Ciphertext -> SharedSecret
end
```

Key encapsulation (FIPS 203, ML-KEM-768): `exchangeKeyPair` makes a fresh
key pair; `encapsulate` makes a shared secret and the ciphertext that
carries it to the holder of the secret key; `decapsulate` recovers the
secret. Laws:

- decapsulating gives the encapsulated secret;
- a shared secret is 32 bytes;
- another secret key gives another secret (ML-KEM's implicit rejection).

## Signature

```lawspec fragment
ability Signature is
  signingKeyPair :: SigningKeyPair
  sign :: SigningKey -> Bytes -> SignatureBytes
  verify :: VerifyingKey -> Bytes -> SignatureBytes -> Bool
end
```

Signatures (FIPS 204, ML-DSA-65, hedged, with an empty context). `verify`
holds exactly for the message signed and the signer's key. Laws:

- a signature verifies with the signer's key;
- a changed message fails to verify;
- another key's signature fails to verify.

**SLH-DSA** (FIPS 205, SLH-DSA-SHAKE-128f), a hash-based scheme whose
security rests on SHAKE256 alone, is the alternative handler. Bind it in
`lawspec.json` to use it instead; the Signature laws then check it:

| Target | `native` |
| --- | --- |
| Python | `["lawspec", "crypto", "SlhDsaSignatureHandler"]` |
| JavaScript, TypeScript | `["lawspec", "crypto", "SlhDsaSignatureHandler"]` |
| Go | `["NewSlhDsaSignatureHandler"]` |
| Java, Kotlin | `["lawspec", "Crypto", "SlhDsaSignatureHandler"]` |
| Haskell | `["Lawspec", "Crypto", "slhDsaSignatureHandler"]` |
| Rust | `["crate", "lawspec_crypto", "SlhDsaSignatureHandler"]` |
| Erlang | `["lawspec_crypto", "slh_dsa_signature_handler"]` |
| Elixir | `["Lawspec", "Crypto", "slh_dsa_signature_handler"]` |
| Gleam | `["lawspec", "crypto", "slh_dsa_signature_handler"]` |

Its keys are longer (a 32-byte public key, a 64-byte secret key) and its
signatures 17088 bytes.

## Aead

```lawspec fragment
ability Aead is
  aeadKey :: AeadKey
  deriveAeadKey :: SharedSecret -> Bytes -> AeadKey
  seal :: AeadKey -> Bytes -> Bytes -> Sealed
  unseal :: AeadKey -> Sealed -> Bytes -> Maybe Bytes
end
```

Authenticated encryption with associated data: AES-256-GCM (NIST SP
800-38D) with a fresh random 96-bit nonce per message. `seal key message
associated` encrypts; `unseal` gives `Just` the message, or `Nothing` unless
the key and the associated data are the ones it was sealed with.
`deriveAeadKey secret context` is the first 32 bytes of SHAKE256(secret ||
context): a shared secret from `KeyExchange` becomes a key for one purpose.
Laws: unsealing gives what was sealed; other associated data, or another
key, fails to unseal; a secret and a context give one key, of 32 bytes.

## Building a secure channel

The four abilities are the parts of a handshake, as in the example above:

1. Each side has a long-term `SigningKeyPair`, its identity.
2. A server makes a fresh `ExchangeKeyPair` and signs its public key.
3. The client verifies the signature, encapsulates a secret to the key, and
   derives an `AeadKey` with a context naming the channel.
4. The server decapsulates and derives the same key; messages then cross
   sealed, with their framing as associated data.

`SecureRandom` (see [randomness](randomness.md)) gives tokens.

## Libraries and known-answer tests

| Target | ML-KEM-768 | ML-DSA-65 | SLH-DSA | SHA3, SHAKE | AES-GCM |
| --- | --- | --- | --- | --- | --- |
| Python | `cryptography` | `cryptography` | LawSpec's own, over `hashlib` | `hashlib` | `cryptography` |
| JavaScript, TypeScript | `@noble/post-quantum` | `@noble/post-quantum` | `@noble/post-quantum` | `node:crypto` | `node:crypto` |
| Go | `crypto/mlkem` | `circl` | `circl` | `crypto/sha3` | `crypto/aes` |
| Java, Kotlin | JDK (`KEM`) | JDK (`Signature`) | Bouncy Castle | JDK SHA3-256, Bouncy Castle SHAKE256 | JDK |
| Haskell | `mlkem` | `mldsa` | LawSpec's own, over `crypton` | `crypton` | `crypton` |
| Rust | `ml-kem` | `ml-dsa` | `slh-dsa` | `sha3`, `shake` | `aes-gcm` |
| Erlang, Elixir, Gleam | OTP 29 `crypto`, OpenSSL seed bridge | OTP 29 `crypto`, OpenSSL seed bridge | OTP 29 `crypto` | OTP 29 `crypto` | OTP 29 `crypto` |

### BEAM builds

The three BEAM targets keep the same compact seed encodings as the other
targets. OTP 29's `crypto` API does not expose expansion of those seeds into
key pairs. A small generated OpenSSL NIF supplies that operation, signature
contexts and deterministic operations for the vector tests. Normal signing,
encapsulation, verification, hashing and authenticated encryption use OTP.
The underlying APIs are documented in [OTP crypto](https://www.erlang.org/doc/apps/crypto/crypto.html)
and [OpenSSL's ML-DSA key management](https://docs.openssl.org/3.5/man7/EVP_PKEY-ML-DSA/).

Install OTP 29 with the algorithms above, a Unix C compiler and OpenSSL
development headers and libraries, version 3.5 or newer. The development
installation must have the same OpenSSL major version as OTP. On Windows,
build and run these crypto projects in WSL. After generating the project,
run this from its root before the native compile, test or export command:

```sh
escript lawspec_crypto_build.escript
```

The builder finds OpenSSL through `pkg-config` or Homebrew. Set
`LAWSPEC_OPENSSL_PREFIX` to select a different installation and `CC` to
select one compiler executable. Paths may contain spaces. The build checks
OTP's algorithms and the OpenSSL ABI, and only recompiles when its inputs
or compiled output change. It does not download dependencies.

The output is `priv/lawspec_crypto_native.so`. Keep `priv/` with the
application when releasing it; Rebar and Mix application layouts and Gleam's
Erlang shipment carry this directory. Build for the destination's OS and
architecture, with the matching OpenSSL runtime installed there. Application
startup loads the compiled library and does not invoke a compiler. Projects
without `lawspec.crypto` or `lawspec.network` do not need this bridge.

Native factories are `lawspec_crypto:hash_handler/0`,
`Lawspec.Crypto.hash_handler/0` and `lawspec/crypto.hash_handler()`;
`key_exchange_handler`, `signature_handler`, `slh_dsa_signature_handler`
and `aead_handler` follow the same convention. They return native ability
interfaces that can be passed to checked public definitions. Crypto
factories do not require a mutable handler scope.

### Vector coverage

A program that imports `lawspec.crypto` gets a generated test of these
primitives against NIST's vectors, beside its law tests. The vectors are in
`runtime/defaults/vectors.txt`, made by `dev/crypto-vectors.py`, from:

- NIST's ACVP server (`usnistgov/ACVP-Server`, `gen-val/json-files`):
  SHA3-256 and SHAKE256 (FIPS 202), ML-KEM-768 key generation, encapsulation
  and decapsulation (FIPS 203), ML-DSA-65 key generation and verification
  (FIPS 204), and SLH-DSA-SHAKE-128f key generation and verification (FIPS
  205);
- NIST's CAVP AES-GCM vectors (`gcmEncryptExtIV256.rsp`, SP 800-38D);
- two derived vectors, for libraries that take keys only as seeds: an ACVP
  key, a deterministic encapsulation and a deterministic ML-DSA signature
  with an empty context, computed with `@noble/post-quantum` and checked
  against Haskell's `mlkem` and `mldsa`.

Every target runs every vector, but one:

- Python's `cryptography` encapsulates only with fresh randomness, takes keys
  only as seeds and signs only hedged, so its test also carries a plain
  reference of ML-KEM-768 and ML-DSA-65, written from FIPS 203 and 204 and
  used by the test alone. The encapsulation and expanded-key vectors run on
  it, the deterministic signature is compared byte for byte, and the library
  must agree with it on keys, decapsulation and verification.
- Go runs the encapsulation vectors from Go 1.26, through
  `crypto/mlkem/mlkemtest`, and takes decapsulation keys as seeds, so it
  runs the derived seed vectors rather than the expanded-key one.
- The JDK's ML-DSA takes no context strings, so Java and Kotlin verify
  signatures with a context through Bouncy Castle's ML-DSA.
- BEAM targets use the generated OpenSSL bridge for deterministic key
  generation, encapsulation and signing, and for signature contexts. OTP
  checks the resulting signatures and performs seed-expanded and ordinary
  expanded-key decapsulation. All vector families run on all three targets;
  Gleam keeps the vector runner in its development-only test package.
- Deterministic ML-DSA signatures are compared byte for byte on every
  target.

## References

- NIST FIPS 202, *SHA-3 Standard: Permutation-Based Hash and Extendable-Output
  Functions*, 2015.
- NIST FIPS 203, *Module-Lattice-Based Key-Encapsulation Mechanism
  Standard*, 2024.
- NIST FIPS 204, *Module-Lattice-Based Digital Signature Standard*, 2024.
- NIST FIPS 205, *Stateless Hash-Based Digital Signature Standard*, 2024.
- NIST SP 800-38D, *Recommendation for Block Cipher Modes of Operation:
  Galois/Counter Mode (GCM) and GMAC*, 2007.
