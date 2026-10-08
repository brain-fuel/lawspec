defmodule Till.Cash do
  @enforce_keys [:cash_cents]
  defstruct [:cash_cents]
end

defmodule Till.CardDeclined do
  defexception message: "declined"
end

defmodule Till.BadAmount do
  defexception [:message]
end

defmodule Till.Native do
  alias Till.Cash
  alias LawSpec.Data.Money

  def new_native_till() do
    taken = :lawspec_beam_effects.native_cell(0)
    %{take: fn %Cash{cash_cents: cents} ->
        :lawspec_beam_effects.native_write(taken, :lawspec_beam_effects.native_read(taken) + cents)
        %Cash{cash_cents: cents}
      end,
      opening: fn -> %Cash{cash_cents: 0} end}
  end

  def pay(_drawer, cents) when cents < 0, do: raise(Till.BadAmount, message: "negative")
  def pay(_drawer, cents) when cents > 1000, do: raise(Till.CardDeclined)
  def pay(drawer, cents) do
    %Money{cents: paid} = drawer.take.(%Money{cents: cents})
    %Cash{cash_cents: paid}
  end
end
