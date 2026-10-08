%% @doc Real-clock timeout and hedge scheduling. Logical Left values lose a
%% hedge; the first success wins, or the last failure after every attempt.
%% Closing the task scope joins losing attempts and their nested workers.
%% ref:DEC-async-native-tasks ref:DEC-domain-modeling-primitives
-module(lawspec_beam_attempts).
-export([run/4]).

run(Timeout, Hedge, Body, OnHedge) ->
    lawspec_beam_tasks:with_scope(fun(_) ->
        Context = lawspec_beam_runtime:worker_context(),
        {Coordinator, Monitor} = spawn_monitor(fun() ->
            lawspec_beam_runtime:with_worker_context(Context, fun() ->
                Start = monotonic(),
                Deadline = case Timeout of none -> infinity; N when N =< 0 -> infinity; N -> Start + N end,
                {Delay, Most} = case Hedge of none -> {0, 1}; {D, M} -> {max(0, D), max(1, M)} end,
                Config = #{body => Body, context => Context, deadline => Deadline,
                    delay => Delay, most => Most, event => OnHedge},
                Outcome = try {ok, loop(launch(Config, #{}, 1), Config, 1, Start + Delay)}
                    catch Class:Reason:Stack -> {exception, Class, Reason, Stack} end,
                exit({lawspec_attempt, Outcome})
            end)
        end),
        %% The scope monitors the caller and owns the coordinator as well as its
        %% descendants. Only this private monitor is consumed from its mailbox.
        receive
            {'DOWN', Monitor, process, Coordinator, {lawspec_attempt, {ok, Value}}} -> Value;
            {'DOWN', Monitor, process, Coordinator, {lawspec_attempt, {exception, Class, Reason, Stack}}} ->
                erlang:raise(Class, Reason, Stack);
            {'DOWN', Monitor, process, Coordinator, Reason} -> error({lawspec, {attempt_group_failed, Reason}})
        end
    end).

monotonic() -> erlang:monotonic_time(microsecond).

launch(#{body := Body, context := Context, event := Event}, Workers, Number) ->
    case Number > 1 of true -> Event(Number); false -> ok end,
    {Pid, Monitor} = spawn_monitor(fun() ->
        Outcome = try lawspec_beam_runtime:with_worker_context(Context, Body) of
            Value -> {ok, Value}
        catch Class:Reason:Stack -> {exception, Class, Reason, Stack} end,
        exit({lawspec_attempt_result, monotonic(), Outcome})
    end),
    Workers#{Monitor => Pid}.

loop(Workers, #{deadline := Deadline} = Config, Started, Next) ->
    Current = monotonic(),
    Most = maps:get(most, Config),
    Timer = case Started < Most of true -> min_deadline(Deadline, Next); false -> Deadline end,
    receive
        {'DOWN', Monitor, process, Pid, Reason} when is_map_key(Monitor, Workers) ->
            Pid = maps:get(Monitor, Workers),
            Rest = maps:remove(Monitor, Workers),
            case Reason of
                {lawspec_attempt_result, Ended, _} when Deadline =/= infinity, Ended > Deadline ->
                    lawspec_beam_policy:stage_failure(<<"TimedOut">>);
                {lawspec_attempt_result, _, {ok, Value}} ->
                    case lawspec_beam_policy:failed(Value) of
                        false -> Value;
                        true when map_size(Rest) =:= 0, Started >= Most -> Value;
                        true when map_size(Rest) =:= 0 ->
                            case Deadline =:= infinity orelse monotonic() < Deadline of
                                true -> loop(launch(Config, Rest, Started + 1), Config, Started + 1,
                                    monotonic() + maps:get(delay, Config));
                                false -> lawspec_beam_policy:stage_failure(<<"TimedOut">>)
                            end;
                        true -> loop(Rest, Config, Started, Next)
                    end;
                {lawspec_attempt_result, _, {exception, Class, Why, Stack}} -> erlang:raise(Class, Why, Stack);
                _ -> error({lawspec, {attempt_failed, Reason}})
            end
    after milliseconds(Timer, Current) ->
        Now = monotonic(),
        case Deadline =/= infinity andalso Now >= Deadline of
            true -> lawspec_beam_policy:stage_failure(<<"TimedOut">>);
            false when Started < Most, Now >= Next ->
                loop(launch(Config, Workers, Started + 1), Config, Started + 1,
                    monotonic() + maps:get(delay, Config));
            false -> loop(Workers, Config, Started, Next)
        end
    end.

min_deadline(infinity, Other) -> Other;
min_deadline(One, Two) -> min(One, Two).
milliseconds(infinity, _) -> infinity;
milliseconds(Deadline, Current) -> min(16#ffffffff, max(0, (Deadline - Current + 999) div 1000)).
