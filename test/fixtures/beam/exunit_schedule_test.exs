# Scheduler lifetimes are checked independently of native report assertions.
# ref:REQ-harness-units ref:DEC-async-native-tasks ref:DEC-tests-cite-requirements
ExUnit.start()

defmodule LawSpec.Beam.ExUnitScheduleLifecycleTest do
  use ExUnit.Case, async: false
  alias LawSpec.Beam.ExUnitSchedule, as: Schedule

  test "close joins started cases but cancels a queued request without evaluating it" do
    parent = self()
    first = fn ->
      table = :ets.new(:private_resource, [:private])
      :ets.insert(table, {:owner, self()})
      send(parent, {:started, self()})
      try do
        receive do :finish -> :finished end
      after
        [{:owner, owner}] = :ets.lookup(table, :owner)
        assert owner == self()
        :ets.delete(table)
        send(parent, {:released, self()})
      end
    end
    {:ok, schedule} = GenServer.start(Schedule, {parent, "close fixture", false, 1, :infinity,
      [{:first, first}, {:queued, fn -> send(parent, :queued_started) end}]})
    running = Task.async(fn -> Schedule.await(schedule, :first) end)
    assert_receive {:started, worker}
    queued = Task.async(fn ->
      try do Schedule.await(schedule, :queued)
      catch :exit, reason -> {:closed, reason} end
    end)
    # Wait until the request is registered; do not rely on wall-clock ordering.
    wait_until(fn -> Map.has_key?(:sys.get_state(schedule).waiters, :queued) end)
    closing = Task.async(fn -> Schedule.close(schedule) end)
    assert Task.await(queued) == {:closed, :lawspec_schedule_closed}
    assert Task.yield(closing, 10) == nil
    send(worker, :finish)
    assert Task.await(running) == :finished
    assert Task.await(closing) == :ok
    assert_receive {:released, ^worker}
    refute Process.alive?(worker)
    refute Process.alive?(schedule)
    refute_receive :queued_started, 10
    assert Schedule.close(schedule) == :ok
  end

  test "owner termination drains an existing case before the pool exits" do
    parent = self()
    owner = spawn(fn ->
      {:ok, schedule} = GenServer.start(Schedule, {self(), "owner fixture", false, 1, :infinity,
        [{:case, fn ->
          send(parent, {:started, self()})
          receive do :finish -> send(parent, :finished) end
        end}]})
      send(parent, {:schedule, schedule})
      receive do :exit -> :ok end
    end)
    assert_receive {:schedule, schedule}
    monitor = Process.monitor(schedule)
    running = Task.async(fn -> Schedule.await(schedule, :case) end)
    assert_receive {:started, worker}
    send(owner, :exit)
    wait_until(fn -> :sys.get_state(schedule).closing end)
    assert Process.alive?(worker)
    send(worker, :finish)
    assert Task.await(running) == :finished
    assert_receive :finished
    assert_receive {:DOWN, ^monitor, :process, ^schedule, :normal}
    refute Process.alive?(worker)
  end

  test "a native timeout joins nested async workers before returning the exception" do
    parent = self()
    body = fn ->
      send(parent, {:entered, :root, self()})
      :lawspec_beam_runtime.async_call(fn ->
        send(parent, {:entered, :child, self()})
        :lawspec_beam_runtime.async_call(fn ->
          send(parent, {:entered, :grandchild, self()})
          receive do :never -> :ok end
        end)
      end)
    end
    {:ok, schedule} = GenServer.start(Schedule, {parent, "timeout fixture", false, 1, 100, [{:case, body}]})
    assert_raise ExUnit.TimeoutError, fn -> Schedule.await(schedule, :case) end
    for label <- [:root, :child, :grandchild] do
      assert_receive {:entered, ^label, pid}
      refute Process.alive?(pid)
    end
    assert Schedule.close(schedule) == :ok
  end

  test "reporting faults fail passing cases and preserve an original law failure" do
    path = Path.join(System.tmp_dir!(), "lawspec-schedule-statistics-#{System.unique_integer([:positive])}")
    File.write!(path, "a file cannot be used as the statistics directory")
    previous = System.get_env("LAWSPEC_STATS")
    System.put_env("LAWSPEC_STATS", path)
    try do
      for {run, exception, message} <- [
        {fn -> :passed end, MatchError, ~r/no match of right hand side value/},
        {fn -> raise "original law failure" end, RuntimeError, "original law failure"}
      ] do
        diagnostic = ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {:ok, schedule} = GenServer.start(Schedule, {self(), "report fixture", true, 1, :infinity, [{:case, run}]})
          assert_raise exception, message, fn -> Schedule.await(schedule, :case) end
          assert_raise MatchError, fn -> Schedule.close(schedule) end
          refute Process.alive?(schedule)
        end)
        assert length(Regex.scan(~r/LawSpec parallel statistics failed:/, diagnostic)) == 1
      end
    after
      if previous == nil, do: System.delete_env("LAWSPEC_STATS"), else: System.put_env("LAWSPEC_STATS", previous)
      File.rm!(path)
    end
  end

  defp wait_until(condition, attempts \\ 200)
  defp wait_until(_, 0), do: flunk("scheduler state did not settle")
  defp wait_until(condition, attempts) do
    unless condition.() do
      Process.sleep(1)
      wait_until(condition, attempts - 1)
    end
  end
end
