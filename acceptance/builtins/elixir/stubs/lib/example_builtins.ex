# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Builtins do
  @spec elapsed(LawSpec.Abilities.Lawspec.Time.Clock.t(), -2_147_483_648..2_147_483_647) ::
          LawSpec.Data.duration()

  def elapsed(_clock_handler, _int32) do
    raise "Not implemented: example.builtins::elapsed"
  end

  @spec token(
          LawSpec.Abilities.Lawspec.Randomness.SecureRandom.t(),
          -2_147_483_648..2_147_483_647
        ) :: binary()

  def token(_secure_random_handler, _int32) do
    raise "Not implemented: example.builtins::token"
  end

  @spec listening(LawSpec.Abilities.Lawspec.Host.Ports.t(), -2_147_483_648..2_147_483_647) ::
          boolean()

  def listening(_ports_handler, _int32) do
    raise "Not implemented: example.builtins::listening"
  end

  @spec charge(LawSpec.Abilities.Lawspec.Logging.Log.t(), -2_147_483_648..2_147_483_647) ::
          boolean()

  def charge(_log_handler, _int32) do
    raise "Not implemented: example.builtins::charge"
  end
end
