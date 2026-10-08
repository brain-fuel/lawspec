# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Crypto do
  @spec fingerprint(LawSpec.Abilities.Lawspec.Crypto.Hash.t(), binary()) :: binary()

  def fingerprint(_handler0, _argument0) do raise "Not implemented: example.crypto::fingerprint" end

  @spec round_trip(LawSpec.Abilities.Lawspec.Crypto.Aead.t(), binary()) :: boolean()

  def round_trip(_handler0, _argument0) do raise "Not implemented: example.crypto::roundTrip" end
end
