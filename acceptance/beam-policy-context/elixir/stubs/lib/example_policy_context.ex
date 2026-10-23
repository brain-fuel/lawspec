# User-owned LawSpec adapter. Implement these functions.
defmodule Example.PolicyContext do
  @spec step(-2_147_483_648..2_147_483_647) :: {
          :left,
          binary()} | {:right,
          -2_147_483_648..2_147_483_647
        }

  def step(_int32) do
    raise "Not implemented: example.policy_context::step"
  end

  @spec undo(-2_147_483_648..2_147_483_647) :: boolean()

  def undo(_int32) do
    raise "Not implemented: example.policy_context::undo"
  end

  @spec always_fail(-2_147_483_648..2_147_483_647) :: {
          :left,
          binary()} | {:right,
          -2_147_483_648..2_147_483_647
        }

  def always_fail(_int32) do
    raise "Not implemented: example.policy_context::alwaysFail"
  end

  @spec native_probe(:ok) :: boolean()

  def native_probe(_unit) do
    raise "Not implemented: example.policy_context::nativeProbe"
  end
end
