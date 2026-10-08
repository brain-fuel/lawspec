# User-owned LawSpec adapter. Implement these functions.
defmodule Example.HandlerContext do
  @spec roundtrip(LawSpec.Abilities.Example.HandlerContext.Counter.t(), -2147483648..2147483647) ::
    integer()

  def roundtrip(_handler0, _argument0) do
    raise "Not implemented: example.handlerContext::roundtrip"
  end

  @spec public_probe(:ok) :: boolean()

  def public_probe(_argument0) do raise "Not implemented: example.handlerContext::publicProbe" end

  @spec counter_handler() :: LawSpec.Abilities.Example.HandlerContext.Counter.t()

  def counter_handler() do
    %LawSpec.Abilities.Example.HandlerContext.Counter{bump: fn _argument0 -> raise "Not implemented: example.handlerContext::ability::Counter.bump" end, current: fn  -> raise "Not implemented: example.handlerContext::ability::Counter.current" end}
  end

  @spec offset_handler() :: LawSpec.Abilities.Example.HandlerContext.Offset.t()

  def offset_handler() do
    %LawSpec.Abilities.Example.HandlerContext.Offset{offset: fn  -> raise "Not implemented: example.handlerContext::ability::Offset.offset" end}
  end
end
