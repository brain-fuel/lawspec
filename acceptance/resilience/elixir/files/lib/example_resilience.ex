# ref:DEC-acceptance-with-mutants
defmodule Example.Resilience do
  alias Example.Limits.Definitions
  alias LawSpec.{Data, Workflow}
  def runtime_exponential_delay(base, factor, attempt),
    do: :lawspec_beam_policy.retry_delay({:exponential, base, factor, :none}, attempt)
  def runtime_linear_delay(base, step, attempt),
    do: :lawspec_beam_policy.retry_delay({:linear, base, step}, attempt)
  def runtime_fibonacci_delay(base, attempt), do: :lawspec_beam_policy.retry_delay({:fibonacci, base}, attempt)
  def split_mix(seed, count), do: :beam_policy_probe.split_mix(seed, count)
  def full_jitter(seed, delay), do: :beam_policy_probe.full_jitter(seed, delay)
  def retried_waits(attempts), do: :beam_policy_probe.waits(attempts, true)
  def rejected_waits(attempts), do: :beam_policy_probe.waits(attempts, false)
  def limited_at(times) do
    Workflow.with_virtual(fn runtime ->
      Enum.map(times, fn time ->
        Workflow.set_time(runtime, time)
        match?({:right, _}, Definitions.limited(%Data.Ticket{number: 0}))
      end)
    end)
  end
  def compensations_for(n) do
    Workflow.with_virtual(fn runtime ->
      Definitions.book(%Data.Ticket{number: n})
      for {"compensate", name, _, _} <- Workflow.trace(runtime), do: name
    end)
  end
  def quote_timed_out(n) do
    Workflow.with_real(fn _ ->
      Definitions.quoted(%Data.Ticket{number: n}) == {:left, %Data.QuotedErrorQuotedTimedOut{}}
    end)
  end
  def quote_hedged(n) do
    :beam_policy_probe.with_quotes(fn ->
      runtime = :lawspec_beam_workflow.current(%{})
      started = System.monotonic_time(:millisecond)
      result = Definitions.hedged(%Data.Ticket{number: n})
      quick = System.monotonic_time(:millisecond) - started < 400
      hedged = Enum.any?(Workflow.trace(runtime), fn {kind, _, _, _} -> kind == "hedge" end)
      result == {:right, %Data.Ticket{number: n}} and quick and (n != -2 or hedged)
    end)
  end
end
