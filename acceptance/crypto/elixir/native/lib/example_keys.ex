defmodule Example.Keys do
  def counting_signer do
    inner = Lawspec.Crypto.signature_handler()
    count = :lawspec_beam_effects.native_cell(0)
    %{signing_key_pair: inner.signing_key_pair,
      sign: fn key, message -> increment(count); inner.sign.(key, message) end,
      verify: fn key, message, signature -> inner.verify.(key, message, signature) end}
  end

  def counting_exchange do
    inner = Lawspec.Crypto.key_exchange_handler()
    count = :lawspec_beam_effects.native_cell(0)
    %{exchange_key_pair: inner.exchange_key_pair,
      encapsulate: fn key -> increment(count); inner.encapsulate.(key) end,
      decapsulate: fn key, ciphertext -> inner.decapsulate.(key, ciphertext) end}
  end

  defp increment(cell), do: :lawspec_beam_handler.call(cell, fn n -> {:ok, n + 1} end)
end
