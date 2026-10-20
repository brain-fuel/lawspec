# ref:DEC-acceptance-with-mutants
defmodule Example.BeamFailures do
  def refund(n) when n < 0 do
    :lawspec_beam_effects.fail(%LawSpec.Data.RejectionDeclined{value: %LawSpec.Data.Recordf5f10555f6c6efcfede6a1b5b3a543dda5cd98cceb0297c257aa71c41066c7c7{message: "negative refund"}})
  end

  def refund(n) when n > 5000 do
    :lawspec_beam_effects.fail(%LawSpec.Data.RejectionLimit{value: 5000})
  end

  def refund(n), do: n
  def checked_limit(n), do: Example.BeamFailures.Definitions.limit(n)
end
