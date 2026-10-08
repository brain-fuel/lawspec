# ref:DEC-acceptance-with-mutants
defmodule Example.PolicyContext do
  alias Example.PolicyContext.Definitions
  def step(n), do: if(:beam_policy_context_probe.succeeds(n), do: {:right, n}, else: {:left, "retry"})
  def undo(n), do: :beam_policy_context_probe.undo(n)
  def always_fail(_), do: {:left, "stopped"}
  def native_probe(:ok), do: :beam_policy_context_probe.check([
    {"fixed", fn n -> match?({:right, _}, Definitions.fixed(n)) end},
    {"linear", fn n -> match?({:right, _}, Definitions.linear(n)) end},
    {"fibonacci", fn n -> match?({:right, _}, Definitions.fibonacci(n)) end},
    {"custom", fn n -> match?({:right, _}, Definitions.custom(n)) end},
    {"rejected", fn n -> match?({:right, _}, Definitions.rejected(n)) end},
    {"cached", fn n -> match?({:right, _}, Definitions.cached(n)) end},
    {"broken", fn n -> match?({:right, _}, Definitions.broken(n)) end},
    {"bounded", fn n -> match?({:right, _}, Definitions.bounded(n)) end},
    {"waiting", fn n -> match?({:right, _}, Definitions.waiting(n)) end},
    {"compensated", fn n -> match?({:right, _}, Definitions.compensated(n)) end}
  ])
end
