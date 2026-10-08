# User-owned LawSpec adapter. Implement these functions.
defmodule Example.PolicyContext do
  @spec step(-2147483648..2147483647) :: {:left, binary()} | {:right, -2147483648..2147483647}

  def step(_argument0) do raise "Not implemented: example.policy_context::step" end

  @spec undo(-2147483648..2147483647) :: boolean()

  def undo(_argument0) do raise "Not implemented: example.policy_context::undo" end

  @spec always_fail(-2147483648..2147483647) ::
    {:left, binary()} | {:right, -2147483648..2147483647}

  def always_fail(_argument0) do raise "Not implemented: example.policy_context::alwaysFail" end

  @spec native_probe(:ok) :: boolean()

  def native_probe(_argument0) do raise "Not implemented: example.policy_context::nativeProbe" end
end
