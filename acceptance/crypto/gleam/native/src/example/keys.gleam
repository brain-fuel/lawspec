import lawspec/abilities/lawspec/crypto as interface
import lawspec/crypto
import lawspec/data
import lawspec/effects

pub type CountingSigner {
  CountingSigner(
    signing_key_pair: fn() -> data.SigningKeyPair,
    sign: fn(data.SigningKey, BitArray) -> data.SignatureBytes,
    verify: fn(data.VerifyingKey, BitArray, data.SignatureBytes) -> Bool,
  )
}

pub fn counting_signer() -> CountingSigner {
  let inner = crypto.signature_handler()
  let count = effects.new_cell(0)
  CountingSigner(
    fn() { interface.signature_signing_key_pair(inner) },
    fn(key, message) { increment(count) interface.signature_sign(inner, key, message) },
    fn(key, message, signature) { interface.signature_verify(inner, key, message, signature) },
  )
}

pub type CountingExchange {
  CountingExchange(
    exchange_key_pair: fn() -> data.ExchangeKeyPair,
    encapsulate: fn(data.ExchangePublicKey) -> data.Encapsulated,
    decapsulate: fn(data.ExchangeSecretKey, data.Ciphertext) -> data.SharedSecret,
  )
}

pub fn counting_exchange() -> CountingExchange {
  let inner = crypto.key_exchange_handler()
  let count = effects.new_cell(0)
  CountingExchange(
    fn() { interface.key_exchange_exchange_key_pair(inner) },
    fn(key) { increment(count) interface.key_exchange_encapsulate(inner, key) },
    fn(key, ciphertext) { interface.key_exchange_decapsulate(inner, key, ciphertext) },
  )
}

@external(erlang, "crypto_keys_ffi", "increment")
fn increment(cell: effects.Cell(Int)) -> Nil
