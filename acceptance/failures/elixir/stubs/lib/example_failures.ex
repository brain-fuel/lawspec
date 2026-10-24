# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Failures do
  @spec refund(-2_147_483_648..2_147_483_647) :: -2_147_483_648..2_147_483_647

  def refund(_int32) do
    raise "Not implemented: example.failures::refund"
  end

  @spec settle(-2_147_483_648..2_147_483_647) :: -2_147_483_648..2_147_483_647

  def settle(_int32) do
    raise "Not implemented: example.failures::settle"
  end

  @spec gateway_handler() :: LawSpec.Abilities.Example.Failures.Gateway.t()

  def gateway_handler() do
    %LawSpec.Abilities.Example.Failures.Gateway{
      decide: fn _int32 -> raise "Not implemented: example.failures::ability::Gateway.decide" end
    }
  end
end
