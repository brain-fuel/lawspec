%% ref:DEC-acceptance-with-mutants
-module(beam_policy_probe).
-export([monotonic_millis/0, sleep_millis/1, slow/1, since/0, overlapped/1]).
monotonic_millis() -> erlang:monotonic_time(millisecond).
sleep_millis(Millis) -> timer:sleep(Millis), nil.
%% Order -1's slow checks record when they ran, so approved_quickly can tell
%% whether they ran at the same time. The table is never cleared, so tests
%% running at once cannot erase each other's records. The scoped workflow
%% state identity propagates to workers and isolates each invocation's spans.
%% Another call's overlap cannot satisfy this call. A persistent owner holds it.
spans() ->
    case ets:whereis(example_approval_spans) of
        undefined ->
            Self = self(),
            Owner = spawn(fun() ->
                catch ets:new(example_approval_spans, [named_table, public, bag]),
                Self ! {example_approval_spans, ready},
                receive stop -> ok end
            end),
            receive {example_approval_spans, ready} -> ok after 5000 -> ok end,
            _ = Owner,
            example_approval_spans;
        _ -> example_approval_spans
    end.
slow(Millis) ->
    Start = erlang:monotonic_time(),
    timer:sleep(Millis),
    ets:insert(spans(), {runtime_key(), Start, erlang:monotonic_time()}),
    nil.
runtime_key() -> maps:get(state, lawspec_beam_workflow:current(#{})).
since() -> erlang:monotonic_time().
overlapped(Since) ->
    Ran = [{A, B} || {_Runtime, A, B} <- ets:lookup(spans(), runtime_key()), A >= Since],
    lists:any(fun({I, {A, B}}) ->
        lists:any(fun({C, D}) -> A < D andalso C < B end, lists:nthtail(I, Ran))
    end, lists:zip(lists:seq(1, length(Ran)), Ran)).
