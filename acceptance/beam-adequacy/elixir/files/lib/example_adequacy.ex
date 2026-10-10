# ref:REQ-harness-units
defmodule Example.Adequacy do
  def number(n), do: :beam_adequacy_support.record("number", n)
  def dependent(x, y) do
    :beam_adequacy_support.record("dependent", [x, y])
    y
  end
  def finite(flag), do: :beam_adequacy_support.record("finite", flag)
end
