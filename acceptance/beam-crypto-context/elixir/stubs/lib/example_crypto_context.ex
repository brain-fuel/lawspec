# User-owned LawSpec adapter. Implement these functions.
defmodule Example.CryptoContext do
  @spec native_probe(:ok) :: boolean()

  def native_probe(_unit_1) do
    raise "Not implemented: example.crypto_context::nativeProbe"
  end
end
