# Native factories allocate state owned by the current LawSpec scope.
defmodule Example.Shop do
  alias LawSpec.Abilities.Example.Shop
  alias LawSpec.Data

  def refund(_gateway, cents) when cents > 100000 do
    :lawspec_beam_effects.fail(%Data.PaymentErrorTooLarge{})
  end
  def refund(gateway, cents) do
    %Data.Receipt{cents: paid} = gateway.capture.(cents)
    paid
  end

  def log_handler() do
    lines = :lawspec_beam_effects.native_cell([])
    %Shop.Log{note: fn text ->
      :lawspec_beam_effects.native_write(lines, [text | :lawspec_beam_effects.native_read(lines)])
      :ok
    end}
  end

  def store_int32_handler() do
    stored = :lawspec_beam_effects.native_cell(0)
    %Shop.StoreInt32{
      load: fn -> :lawspec_beam_effects.native_read(stored) end,
      save: fn value -> :lawspec_beam_effects.native_write(stored, value); :ok end
    }
  end

  def store_text_handler() do
    stored = :lawspec_beam_effects.native_cell("")
    %Shop.StoreText{
      load: fn -> :lawspec_beam_effects.native_read(stored) end,
      save: fn text -> :lawspec_beam_effects.native_write(stored, text); :ok end
    }
  end

  def meter_handler(), do: %Shop.Meter{reading: fn -> 3 end}
end
