# ref:DEC-acceptance-with-mutants
defmodule Example.AsyncWorkflows do
  alias LawSpec.Abilities.Example.AsyncWorkflows.Coordination
  alias LawSpec.Data
  alias Example.AsyncWorkflows.Definitions
  def first(coordination, n) do
    coordination.meet.(1)
    coordination.finish.(1)
    if n < 0, do: {:left, "first"}, else: {:right, n}
  end
  def second(coordination, n) do
    coordination.meet.(2)
    coordination.finish.(2)
    if n < 0, do: {:left, "second"}, else: {:right, n}
  end
  def coordination_handler(), do: %Coordination{meet: fn _ -> :ok end, finish: fn _ -> :ok end}
  def public_probe(:ok) do
    :beam_async_probe.probe(fn meet, finish ->
      Definitions.both(%Coordination{meet: meet, finish: finish}, -1) ==
        {:left, %Data.BothErrorBothFailures{error: [
          %Data.BothErrorBothFirstFailed{error: "first"},
          %Data.BothErrorBothSecondFailed{error: "second"}]}}
    end, :ok) and
    :beam_async_probe.probe(fn meet, finish ->
      Definitions.first_failure(%Coordination{meet: meet, finish: finish}, -1) ==
        {:left, %Data.FirstFailureErrorFirstFailureFirstFailed{error: "first"}}
    end, :ok)
  end
end
