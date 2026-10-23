# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Crypto do
  @spec fingerprint(LawSpec.Abilities.Lawspec.Crypto.Hash.t(), binary()) :: binary()

  def fingerprint(_hash_handler, _bytes) do
    raise "Not implemented: example.crypto::fingerprint"
  end

  @spec round_trip(LawSpec.Abilities.Lawspec.Crypto.Aead.t(), binary()) :: boolean()

  def round_trip(_aead_handler, _bytes) do
    raise "Not implemented: example.crypto::roundTrip"
  end
end
