# ref:REQ-harness-units
defmodule Example.Benchmarks do
  alias LawSpec.Abilities.Example.Benchmarks.Meter
  def ordinary(n), do: :beam_benchmark_support.record("ordinary", n)
  def work(n), do: :beam_benchmark_support.record("sync", n)
  def async_work(n), do: :beam_benchmark_support.record("async", n)
  def false_value(:ok), do: :beam_benchmark_support.record("false", false)
  def meter_handler(), do: %Meter{read: fn :ok -> :beam_benchmark_support.record("production", 1337) end}
end
