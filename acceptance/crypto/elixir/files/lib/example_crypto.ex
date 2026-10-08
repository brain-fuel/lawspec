defmodule Example.Crypto do
  def fingerprint(hash, bytes) do
    digest = hash.sha3.(bytes)
    binary_part(digest.value, 0, 8)
  end

  def round_trip(aead, message) do
    key = aead.aead_key.()
    associated = "round trip"
    aead.unseal.(key, aead.seal.(key, message, associated), associated) == {:just, message}
  end
end
