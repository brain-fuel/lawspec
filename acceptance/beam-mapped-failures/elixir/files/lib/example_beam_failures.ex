# ref:DEC-acceptance-with-mutants
defmodule Example.BeamFailures do
  def refund(n) when n < 0 do
    raise Native.Failures.Negative, message: "negative refund"
  end

  def refund(n) when n > 5000 do
    :lawspec_beam_effects.fail(%LawSpec.Data.RejectionLimit{value: 5000})
  end

  def refund(n), do: n
  def checked_limit(n) when n < 0, do: raise(Native.Failures.Blocked)
  def checked_limit(n), do: Example.BeamFailures.Definitions.limit(n)
end
