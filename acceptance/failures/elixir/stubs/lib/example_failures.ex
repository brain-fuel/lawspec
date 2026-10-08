# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Failures do
  @spec refund(-2147483648..2147483647) :: -2147483648..2147483647

  def refund(_argument0) do raise "Not implemented: example.failures::refund" end

  @spec settle(-2147483648..2147483647) :: -2147483648..2147483647

  def settle(_argument0) do raise "Not implemented: example.failures::settle" end

  @spec gateway_handler() :: LawSpec.Abilities.Example.Failures.Gateway.t()

  def gateway_handler() do
    %LawSpec.Abilities.Example.Failures.Gateway{decide: fn _argument0 -> raise "Not implemented: example.failures::ability::Gateway.decide" end}
  end
end
