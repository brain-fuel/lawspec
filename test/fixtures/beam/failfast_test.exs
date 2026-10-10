# Run a real ExUnit suite to completion, including its intentional failures,
# then independently inspect which adapters ran and which resources released.
# ref:REQ-harness-units ref:DEC-tests-cite-requirements
mode = List.first(System.argv()) || "1"
limit = if mode == "pass", do: 1, else: String.to_integer(mode)
ExUnit.start(autorun: false, seed: 0, max_failures: limit, timeout: 2_000)
{:ok, _} = Agent.start(fn -> [] end, name: :lawspec_failfast_audit)
:persistent_term.put(:lawspec_failfast_mode, mode)

defmodule LawSpec.Beam.FailFastFixture do
  def record(event), do: Agent.update(:lawspec_failfast_audit, &[event | &1])
  def events, do: Agent.get(:lawspec_failfast_audit, &Enum.reverse/1)

  def cases do
    for n <- 0..4 do
      {~c"native case", fn ->
        resource(n, fn ->
          case n do
            0 ->
              # The second worker must own its private resources before the
              # first failure is reported. This makes a premature kill visible.
              wait_for_second(200)
              if :persistent_term.get(:lawspec_failfast_mode) != "pass", do: raise("first failure")
            1 ->
              :lawspec_beam_runtime.async_call(fn ->
                resource(:child, fn -> Process.sleep(100) end)
              end)
              if :persistent_term.get(:lawspec_failfast_mode) == "2", do: raise("second failure")
            _ -> Process.sleep(100)
          end
        end)
      end}
    end
  end

  defp wait_for_second(0), do: raise("second case never started")
  defp wait_for_second(attempts) do
    if Enum.any?(events(), fn {event, id, _} -> event == :acquire and id == :child end) do
      :ok
    else
      Process.sleep(5)
      wait_for_second(attempts - 1)
    end
  end

  defp resource(id, body) do
    table = :ets.new(:private_case_resource, [:private])
    :ets.insert(table, {:owner, self()})
    record({:acquire, id, self()})
    try do
      body.()
    after
      [{:owner, owner}] = :ets.lookup(table, :owner)
      true = owner == self()
      :ets.delete(table)
      record({:release, id, self()})
    end
  end
end

defmodule LawSpec.Beam.FailFastFixtureTest do
  use ExUnit.Case, async: false
  setup_all context do
    {:ok, schedule} = LawSpec.Beam.ExUnitSchedule.setup(context, "fail-fast fixture", false, true)
    LawSpec.Beam.FailFastFixture.record({:scheduler, :pool, schedule[:lawspec_schedule]})
    {:ok, schedule}
  end
  for n <- 0..4 do
    @tag lawspec: "law_#{n}", lawspec_order: {n, 0}
    @tag lawspec_case: {LawSpec.Beam.FailFastFixture, :cases, n}, timeout: :infinity
    test "native case #{n}", context do
      LawSpec.Beam.ExUnitSchedule.await(context.lawspec_schedule, context.test)
    end
  end
end

results = ExUnit.run()
events = LawSpec.Beam.FailFastFixture.events()
IO.inspect({results, events}, label: "Fail-fast audit", limit: :infinity)
import ExUnit.Assertions
expected = case mode do
  "pass" -> Enum.to_list(0..4)
  "2" -> [0, 1, 2] # One replacement starts while ExUnit awaits the second result.
  _ -> [0, 1]
end
assert Enum.sort(for {:acquire, n, _} <- events, is_integer(n), do: n) == expected
for {:acquire, id, pid} <- events do
  assert Enum.count(events, &(&1 == {:release, id, pid})) == 1
  refute Process.alive?(pid)
end
for {:scheduler, _, pid} <- events, do: refute(Process.alive?(pid))
assert results.failures == if(mode == "pass", do: 0, else: limit)
assert results.total == if(mode == "pass", do: 5, else: limit)
Agent.stop(:lawspec_failfast_audit)
IO.puts("PASS native ExUnit limit=#{mode}: queued cases stay stopped, started cases and descendants release before suite completion")
