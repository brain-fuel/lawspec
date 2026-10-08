# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Builtins do
  @spec elapsed(LawSpec.Abilities.Lawspec.Time.Clock.t(), -2147483648..2147483647) ::
    LawSpec.Data.duration()

  def elapsed(_handler0, _argument0) do raise "Not implemented: example.builtins::elapsed" end

  @spec token(LawSpec.Abilities.Lawspec.Randomness.SecureRandom.t(), -2147483648..2147483647) ::
    binary()

  def token(_handler0, _argument0) do raise "Not implemented: example.builtins::token" end

  @spec listening(LawSpec.Abilities.Lawspec.Host.Ports.t(), -2147483648..2147483647) :: boolean()

  def listening(_handler0, _argument0) do raise "Not implemented: example.builtins::listening" end

  @spec charge(LawSpec.Abilities.Lawspec.Logging.Log.t(), -2147483648..2147483647) :: boolean()

  def charge(_handler0, _argument0) do raise "Not implemented: example.builtins::charge" end
end
