# ref:REQ-harness-units
defmodule Example.Repetition do
  def number(n), do: :beam_repetition_support.record("number", n)
  def finite(flag), do: :beam_repetition_support.record("finite", flag)
  def transient(_), do: :beam_repetition_support.transient()
  def peak(n), do: :beam_repetition_support.record("peak", n)
end
