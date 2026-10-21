# ref:DEC-acceptance-with-mutants
defmodule Example.Workflows do
  alias LawSpec.Data
  def audit(_), do: true
  def waitlist(%Data.SignupErrorUnavailable{}), do: {:right, %Data.Account{name: "waitlist", age: 18, level: 0}}
  def waitlist(error), do: {:left, error}
  def check_name(%Data.Signup{name: ""}), do: {:left, %Data.SignupErrorMissingName{}}
  def check_name(signup), do: {:right, signup}
  def check_age(%Data.Signup{age: age}) when age < 18, do: {:left, "too young"}
  def check_age(signup), do: {:right, signup}
  def open_account(%Data.Signup{name: "taken"}), do: {:left, %Data.SignupErrorUnavailable{}}
  def open_account(%Data.Signup{name: name, age: age}), do: {:right, %Data.Account{name: name, age: age, level: 1}}
  def check_stock(%Data.Order{number: n} = order) do
    if n == -1, do: slow(400)
    if n < 0, do: {:left, "no stock"}, else: {:right, order}
  end
  def check_credit(%Data.Order{number: n} = order) do
    if n == -1, do: slow(250)
    if n < 0, do: {:left, "no credit"}, else: {:right, order}
  end
  # Order -1's slow checks record when they ran, so approved_quickly can tell
  # whether they ran at the same time. The table is never cleared, so tests
  # running at once cannot erase each other's records. Each call uses its
  # scoped workflow state identity, which the runtime propagates to workers;
  # another call's overlap cannot satisfy this call. A persistent owner holds it.
  defp spans do
    if :ets.whereis(:example_approval_spans) == :undefined do
      parent = self()
      spawn(fn ->
        try do
          :ets.new(:example_approval_spans, [:named_table, :public, :bag])
        rescue
          ArgumentError -> :ok
        end
        send(parent, {:example_approval_spans, :ready})
        receive do
          :stop -> :ok
        end
      end)
      receive do
        {:example_approval_spans, :ready} -> :ok
      after
        5000 -> :ok
      end
    end
    :example_approval_spans
  end
  defp slow(millis) do
    start = System.monotonic_time()
    Process.sleep(millis)
    :ets.insert(spans(), {runtime_key(), start, System.monotonic_time()})
  end
  defp runtime_key, do: :lawspec_beam_workflow.current(%{}) |> Map.fetch!(:state)
  def since, do: System.monotonic_time()
  def overlapped?(since) do
    ran = for {_runtime, a, b} <- :ets.lookup(spans(), runtime_key()), a >= since, do: {a, b}
    ran
    |> Enum.with_index(1)
    |> Enum.any?(fn {{a, b}, i} -> Enum.any?(Enum.drop(ran, i), fn {c, d} -> a < d and c < b end) end)
  end
end
