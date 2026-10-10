# Exercise the real ExUnit host and scheduler with independently recorded
# adapter intervals and private process-owned state.
# ref:REQ-harness-units ref:DEC-tests-cite-requirements
ExUnit.start()
{:ok, _} = Agent.start(fn -> [] end, name: :lawspec_schedule_audit)

defmodule LawSpec.Beam.ScheduleFixture do
  def cases do
    for n <- Enum.to_list(1..6) ++ Enum.to_list(101..103) do
      {~c"native case", fn ->
        table = :ets.new(:case_state, [:private])
        :ets.insert(table, {:owner, self()})
        record(:start, n)
        Process.sleep(if n < 100, do: 5, else: 100)
        [{:owner, owner}] = :ets.lookup(table, :owner)
        true = owner == self()
        :ets.delete(table)
        record(:end, n)
      end}
    end
  end

  defp record(event, n) do
    Agent.update(:lawspec_schedule_audit, &[{event, n, System.monotonic_time(:microsecond)} | &1])
  end
end

defmodule LawSpec.Beam.SequentialFixtureTest do
  use ExUnit.Case, async: false
  setup_all context do
    LawSpec.Beam.ExUnitSchedule.setup(context, "sequential fixture", true, false)
  end
  for n <- 0..5 do
    @tag lawspec: "law_#{div(n, 2)}", lawspec_order: {div(n, 2), rem(n, 2)}
    @tag lawspec_case: {LawSpec.Beam.ScheduleFixture, :cases, n}, timeout: :infinity
    test "native sequential case #{n}", context do
      LawSpec.Beam.ExUnitSchedule.await(context.lawspec_schedule, context.test)
    end
  end
end

defmodule LawSpec.Beam.ParallelFixtureTest do
  use ExUnit.Case, async: false
  setup_all context do
    LawSpec.Beam.ExUnitSchedule.setup(context, "parallel fixture", false, true)
  end
  for n <- 6..8 do
    @tag lawspec: "law_#{n}", lawspec_order: {n, 0}
    @tag lawspec_case: {LawSpec.Beam.ScheduleFixture, :cases, n}, timeout: :infinity
    test "native parallel case #{n}", context do
      LawSpec.Beam.ExUnitSchedule.await(context.lawspec_schedule, context.test)
    end
  end
end

ExUnit.after_suite(fn _ ->
  import ExUnit.Assertions
  events = Agent.get(:lawspec_schedule_audit, &Enum.reverse/1)
  Agent.stop(:lawspec_schedule_audit)
  starts = for {:start, n, _} <- events, do: n
  assert Enum.sort(starts) == Enum.to_list(1..6) ++ Enum.to_list(101..103)
  assert Enum.sort(for {:end, n, _} <- events, do: n) == Enum.sort(starts)
  ordered = :lawspec_beam_schedule.order("sequential fixture", true, [[1, 2], [3, 4], [5, 6]]) |> List.flatten()
  sequential = Enum.filter(events, fn {_, n, _} -> n < 100 end)
  assert Enum.map(sequential, fn {kind, n, _} -> {kind, n} end) ==
    Enum.flat_map(ordered, &[{:start, &1}, {:end, &1}])
  intervals = for {:start, n, start} <- events, {:end, m, stop} <- events, n == m and n > 100, do: {n, start, stop}
  assert Enum.any?(intervals, fn {n, start, stop} ->
    Enum.any?(intervals, fn {m, other_start, other_stop} -> n != m and start < other_stop and other_start < stop end)
  end)
end)
