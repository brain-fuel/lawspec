# ref:REQ-harness-units
defmodule Example.Strategies do
  def numbers(n), do: :beam_strategy_support.record(:numbers, n)
  def parcels(p), do: :beam_strategy_support.record(:parcels, p)
  def dependent(x, y) do
    :beam_strategy_support.record(:dependent, {x, y})
    y
  end
  def defaults(n), do: :beam_strategy_support.record(:defaults, n)
  def wide(n), do: :beam_strategy_support.record(:wide, n)
  def finite(flag), do: :beam_strategy_support.record(:finite, flag)
  def shadowed(n), do: :beam_strategy_support.record(:shadowed, n)
end
