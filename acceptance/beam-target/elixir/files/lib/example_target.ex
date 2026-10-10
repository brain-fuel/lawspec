# ref:REQ-harness-units
defmodule Example.Target do
  def number(n) do
    true = n >= 0 and n <= 1000
    :beam_target_support.record("number", n)
  end
  def dependent(x, y) do
    true = x >= 0 and x < 1000 and y > x and y <= 1000
    :beam_target_support.record("dependent", [x, y])
    y
  end
  def wide(n), do: :beam_target_support.record("wide", n)
end
