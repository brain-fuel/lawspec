defmodule Example.CryptoContext do
  def native_probe(:ok) do
    hash = Lawspec.Crypto.hash_handler()
    exchange = Lawspec.Crypto.key_exchange_handler()
    signature = Lawspec.Crypto.signature_handler()
    slh = Lawspec.Crypto.slh_dsa_signature_handler()
    aead = Lawspec.Crypto.aead_handler()
    digest = hash.sha3.("LawSpec")
    keys = exchange.exchange_key_pair.()
    signer = signature.signing_key_pair.()
    slh_keys = slh.signing_key_pair.()
    message = <<0, 255, 128>>
    context = "native"
    good = Enum.all?([signature, slh], fn handler ->
      Example.CryptoContext.Definitions.handshake(exchange, handler, aead, message, context) == {:just, message}
    end)
    byte_size(digest.value) == 32 and byte_size(hash.shake.(message, 13)) == 13 and
      byte_size(keys.public_key.value) == 1184 and byte_size(keys.secret_key.value) == 64 and
      byte_size(signer.verifying_key.value) == 1952 and byte_size(signer.signing_key.value) == 32 and
      byte_size(slh_keys.verifying_key.value) == 32 and byte_size(slh_keys.signing_key.value) == 64 and good
  end
end
