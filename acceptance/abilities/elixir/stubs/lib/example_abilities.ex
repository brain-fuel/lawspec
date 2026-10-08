# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Abilities do
  @spec charge(LawSpec.Abilities.Example.Abilities.Gateway.t(), -2147483648..2147483647) ::
    boolean()

  def charge(_handler0, _argument0) do raise "Not implemented: example.abilities::charge" end

  @spec gateway_handler() :: LawSpec.Abilities.Example.Abilities.Gateway.t()

  def gateway_handler() do
    %LawSpec.Abilities.Example.Abilities.Gateway{authorize: fn _argument0 -> raise "Not implemented: example.abilities::ability::Gateway.authorize" end, capture: fn _argument0 -> raise "Not implemented: example.abilities::ability::Gateway.capture" end, fee: fn  -> raise "Not implemented: example.abilities::ability::Gateway.fee" end}
  end
end
