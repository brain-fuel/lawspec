# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Remote do
  @spec native_probe(:ok) :: boolean()

  def native_probe(_argument0) do raise "Not implemented: example.remote::nativeProbe" end

  @spec offset_handler() :: LawSpec.Abilities.Example.Remote.Offset.t()

  def offset_handler() do
    %LawSpec.Abilities.Example.Remote.Offset{shift: fn _argument0 -> raise "Not implemented: example.remote::ability::Offset.shift" end}
  end
end
