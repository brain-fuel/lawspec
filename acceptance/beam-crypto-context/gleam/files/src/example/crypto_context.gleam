import example/crypto_context/definitions
import gleam/bit_array
import gleam/option.{Some}
import lawspec/abilities/lawspec/crypto as interface
import lawspec/crypto
import lawspec/data

pub fn native_probe(_unit: Nil) -> Bool {
  let hash = crypto.hash_handler()
  let exchange = crypto.key_exchange_handler()
  let signature = crypto.signature_handler()
  let slh = crypto.slh_dsa_signature_handler()
  let aead = crypto.aead_handler()
  let data.Digest(digest) = interface.hash_sha3(hash, <<"LawSpec":utf8>>)
  let data.ExchangeKeyPair(data.ExchangePublicKey(public), data.ExchangeSecretKey(secret)) = interface.key_exchange_exchange_key_pair(exchange)
  let data.SigningKeyPair(data.VerifyingKey(verifying), data.SigningKey(signing)) = interface.signature_signing_key_pair(signature)
  let data.SigningKeyPair(data.VerifyingKey(slh_public), data.SigningKey(slh_private)) = interface.signature_signing_key_pair(slh)
  let message = <<0, 255, 128>>
  let context = <<"native":utf8>>
  let good = definitions.handshake(exchange, signature, aead, message, context) == Some(message)
    && definitions.handshake(exchange, slh, aead, message, context) == Some(message)
  bit_array.byte_size(digest) == 32 && bit_array.byte_size(interface.hash_shake(hash, message, 13)) == 13
    && bit_array.byte_size(public) == 1184 && bit_array.byte_size(secret) == 64
    && bit_array.byte_size(verifying) == 1952 && bit_array.byte_size(signing) == 32
    && bit_array.byte_size(slh_public) == 32 && bit_array.byte_size(slh_private) == 64 && good
}
