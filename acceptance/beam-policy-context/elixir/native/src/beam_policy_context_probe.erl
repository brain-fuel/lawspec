%% Exercises public generated definitions under independent policy runtimes.
%% ref:DEC-acceptance-with-mutants ref:DEC-domain-modeling-primitives
-module(beam_policy_context_probe).
-export([check/1, succeeds/1, undo/1]).

options() ->
    #{state := State} = lawspec_beam_workflow:current(#{}),
    lawspec_beam_workflow_state:call(State, options).
succeeds(Value) ->
    Options = options(),
    case maps:find(probe, Options) of
        error -> Value >= 0;
        {ok, Count} ->
            atomics:add_get(Count, 1, 1),
            case maps:find(body, Options) of
                {ok, Body} -> Body(Value);
                error -> Value >= 0
            end
    end.
undo(Value) ->
    case maps:find(probe, options()) of
        error -> ok;
        {ok, Count} -> atomics:put(Count, 2, Value), atomics:add_get(Count, 3, 1)
    end, true.
scoped(Options, Body) ->
    Count = atomics:new(3, []),
    lawspec_beam_workflow:with_runtime(Options#{clock => virtual, probe => Count}, fun(Runtime) -> Body(Runtime, Count) end).
waits(Runtime) -> [N || {<<"sleep">>, _, N, _} <- lawspec_beam_workflow:trace(Runtime)].
assert_equal(Expected, Actual) when Expected =:= Actual -> ok;
assert_equal(Expected, Actual) -> error({policy_probe, Expected, Actual}).

check(Entries) ->
    Calls = maps:from_list(Entries),
    lists:foreach(fun({Name, Expected, Attempts}) ->
        scoped(#{}, fun(Runtime, Count) ->
            assert_equal(false, (maps:get(Name, Calls))(-1)),
            assert_equal(Expected, waits(Runtime)),
            assert_equal(Attempts, atomics:get(Count, 1))
        end)
    end, [{<<"fixed">>, [10, 10], 3}, {<<"linear">>, [10, 15, 20], 4},
        {<<"fibonacci">>, [10, 10, 20, 30], 5}, {<<"custom">>, [7, 7], 3}, {<<"rejected">>, [], 1}]),
    scoped(#{}, fun(Runtime, Count) ->
        Call = maps:get(<<"cached">>, Calls),
        assert_equal([true, true, true], [Call(1), Call(1), Call(2)]),
        assert_equal(2, atomics:get(Count, 1)),
        lawspec_beam_workflow:set_time(Runtime, 10),
        assert_equal(true, Call(1)), assert_equal(3, atomics:get(Count, 1)),
        assert_equal([false, false], [Call(-1), Call(-1)]), assert_equal(5, atomics:get(Count, 1))
    end),
    scoped(#{}, fun(Runtime, Count) ->
        Call = maps:get(<<"broken">>, Calls),
        assert_equal([false, false, false], [Call(-1), Call(-1), Call(1)]),
        assert_equal(2, atomics:get(Count, 1)),
        lawspec_beam_workflow:set_time(Runtime, 30),
        assert_equal([true, true], [Call(1), Call(1)]), assert_equal(4, atomics:get(Count, 1))
    end),
    scoped(#{}, fun(Runtime, Count) ->
        Call = maps:get(<<"waiting">>, Calls),
        assert_equal([true, true, true], [Call(1), Call(1), Call(1)]),
        assert_equal(20, lawspec_beam_workflow:now(Runtime)), assert_equal(3, atomics:get(Count, 1))
    end),
    scoped(#{}, fun(Runtime, Count) ->
        assert_equal(false, (maps:get(<<"compensated">>, Calls))(42)),
        assert_equal(42, atomics:get(Count, 2)), assert_equal(1, atomics:get(Count, 3)),
        assert_equal([<<"step">>], [N || {<<"compensate">>, N, _, _} <- lawspec_beam_workflow:trace(Runtime)])
    end),
    bounded(maps:get(<<"bounded">>, Calls), false),
    bounded(maps:get(<<"bounded">>, Calls), true),
    true.

bounded(Call, Cancel) ->
    Test = self(),
    Body = fun
        (1) -> Test ! {entered, self()}, receive proceed -> true end;
        (_) -> true
    end,
    scoped(#{body => Body}, fun(_, Count) ->
        Context = lawspec_beam_runtime:worker_context(),
        {Worker, Monitor} = spawn_monitor(fun() ->
            lawspec_beam_runtime:with_worker_context(Context, fun() ->
                Result = Call(1), Test ! {finished, self(), Result}
            end)
        end),
        receive {entered, Worker} -> ok after 1000 -> error(missing_first_admission) end,
        assert_equal(false, Call(2)), assert_equal(1, atomics:get(Count, 1)),
        case Cancel of
            true -> exit(Worker, kill);
            false -> Worker ! proceed,
                receive {finished, Worker, Result} -> assert_equal(true, Result)
                after 1000 -> error(missing_result) end
        end,
        receive {'DOWN', Monitor, process, Worker, _} -> ok after 1000 -> error(worker_leaked) end,
        assert_equal(true, Call(3)), assert_equal(2, atomics:get(Count, 1))
    end).
