# User-owned LawSpec adapter. Implement these functions.
defmodule Example.Shop do
  @spec refund(LawSpec.Abilities.Example.Abilities.Gateway.t(), -2_147_483_648..2_147_483_647) ::
          -2_147_483_648..2_147_483_647

  def refund(_gateway_handler, _int32) do
    raise "Not implemented: example.shop::refund"
  end

  @spec log_handler() :: LawSpec.Abilities.Example.Shop.Log.t()

  def log_handler() do
    %LawSpec.Abilities.Example.Shop.Log{
      note: fn _text -> raise "Not implemented: example.shop::ability::Log.note" end
    }
  end

  @spec store_int32_handler() :: LawSpec.Abilities.Example.Shop.StoreInt32.t()

  def store_int32_handler() do
    %LawSpec.Abilities.Example.Shop.StoreInt32{
      load: fn -> raise "Not implemented: example.shop::ability::Store(Int32).load" end,
      save: fn _int32 -> raise "Not implemented: example.shop::ability::Store(Int32).save" end
    }
  end

  @spec store_text_handler() :: LawSpec.Abilities.Example.Shop.StoreText.t()

  def store_text_handler() do
    %LawSpec.Abilities.Example.Shop.StoreText{
      load: fn -> raise "Not implemented: example.shop::ability::Store(Text).load" end,
      save: fn _text -> raise "Not implemented: example.shop::ability::Store(Text).save" end
    }
  end

  @spec meter_handler() :: LawSpec.Abilities.Example.Shop.Meter.t()

  def meter_handler() do
    %LawSpec.Abilities.Example.Shop.Meter{
      reading: fn -> raise "Not implemented: example.shop::ability::Meter.reading" end
    }
  end
end
