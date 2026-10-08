defmodule Example.HandlerContext do
  alias LawSpec.Abilities.Example.HandlerContext, as: Abilities
  alias LawSpec.Handlers.ExampleHandlerContext, as: Handlers
  alias Example.HandlerContext.Definitions

  def roundtrip(counter, amount), do: Definitions.shifted(counter, amount)

  def async_roundtrip(counter, amount) do
    scratch = :lawspec_beam_effects.native_cell(amount)
    Definitions.shifted(counter, :lawspec_beam_effects.native_read(scratch))
  end

  def public_probe(:ok) do
    :lawspec_abilities.with_context(fn context ->
      counter = Handlers.fresh_counter(context)
      recorded = Handlers.recording_counter(context, counter)
      Definitions.advance(recorded, 2) == 2 and Definitions.shifted(recorded, 3) == 105
    end)
  end

  def counter_handler() do
    total = :lawspec_beam_effects.native_cell(0)
    %Abilities.Counter{
      bump: fn amount -> :lawspec_beam_effects.native_write(total, :lawspec_beam_effects.native_read(total) + amount) end,
      current: fn -> :lawspec_beam_effects.native_read(total) end
    }
  end

  def offset_handler(), do: %Abilities.Offset{offset: fn -> 0 end}
end
