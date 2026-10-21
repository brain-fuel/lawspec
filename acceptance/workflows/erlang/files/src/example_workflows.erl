%% ref:DEC-acceptance-with-mutants
-module(example_workflows).
-export([audit/1, waitlist/1, check_name/1, check_age/1, open_account/1, check_stock/1, check_credit/1,
         since/0, overlapped/1]).
audit(_) -> true.
waitlist(signup_error_unavailable) -> {right, {account, <<"waitlist">>, 18, 0}};
waitlist(Error) -> {left, Error}.
check_name({signup, <<>>, _}) -> {left, signup_error_missing_name};
check_name(Signup) -> {right, Signup}.
check_age({signup, _, Age}) when Age < 18 -> {left, <<"too young">>};
check_age(Signup) -> {right, Signup}.
open_account({signup, <<"taken">>, _}) -> {left, signup_error_unavailable};
open_account({signup, Name, Age}) -> {right, {account, Name, Age, 1}}.
check_stock({order, N} = Order) ->
    case N of -1 -> slow(400); _ -> ok end,
    case N < 0 of true -> {left, <<"no stock">>}; false -> {right, Order} end.
check_credit({order, N} = Order) ->
    case N of -1 -> slow(250); _ -> ok end,
    case N < 0 of true -> {left, <<"no credit">>}; false -> {right, Order} end.
%% Order -1's slow checks record when they ran, so approved_quickly can tell
%% whether they ran at the same time. The table is never cleared, so tests
%% running at once cannot erase each other's records; a process that lives
%% on owns it.
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
    ets:insert(spans(), {span, Start, erlang:monotonic_time()}),
    ok.
since() -> erlang:monotonic_time().
overlapped(Since) ->
    Ran = [{A, B} || {span, A, B} <- ets:lookup(spans(), span), A >= Since],
    lists:any(fun({I, {A, B}}) ->
        lists:any(fun({C, D}) -> A < D andalso C < B end, lists:nthtail(I, Ran))
    end, lists:zip(lists:seq(1, length(Ran)), Ran)).
