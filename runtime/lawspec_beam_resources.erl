%% @doc One test run owns its shared resources. Cases borrow monitored leases;
%% closing the run drains them, then releases in reverse acquisition order.
%% No application callback executes in the registry process.
%% ref:REQ-harness-units ref:REQ-law-primitives
-module(lawspec_beam_resources).
-behaviour(gen_server).
-export([start/0, start/1, start_suite/0, configure_suite/1, stop_suite/0, close/1, with_run/1, with_run/2,
    current/0, with_shared/7, with_resource/4, with_case_run/2, watch_case/1, finish_case/2, checkout/7, checkin/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start() -> start(5000).
start(CleanupTimeout) when is_integer(CleanupTimeout), CleanupTimeout > 0 ->
    gen_server:start(?MODULE, {self(), CleanupTimeout}, []).
start_suite() -> gen_server:start({local, ?MODULE}, ?MODULE, self(), []).
%% ExUnit can repeat a suite in the same VM. The test helper installs its
%% after_suite cleanup once; each run then acquires a new lazy registry.
configure_suite(Owner) when is_pid(Owner) ->
    persistent_term:put({?MODULE, suite_owner}, Owner), ok.
stop_suite() -> case whereis(?MODULE) of undefined -> ok; Run -> close(Run) end.
watch_case(none) -> ok;
watch_case(Run) -> unwrap_run(gen_server:call(Run, watch_case, infinity)).
finish_case(none, _) -> ok;
finish_case(Run, Result) -> gen_server:call(Run, {case_finished, Result}, infinity).
unwrap_run(ok) -> ok;
unwrap_run({error, Reason}) -> error({lawspec, Reason}).

with_run(Body) ->
    {ok, Run} = start(),
    try with_run(Run, fun() -> Body(Run) end) after close(Run) end.
with_run(Run, Body) ->
    with_context(run, Run, Body).
with_case_run(Run, Body) -> with_context(case_run, Run, Body).
with_context(Name, Run, Body) ->
    Key = {?MODULE, Name}, Previous = put(Key, Run),
    try Body() after
        case Previous of undefined -> erase(Key); _ -> put(Key, Previous) end
    end.
current() ->
    case get({?MODULE, run}) of
        Run when is_pid(Run) -> Run;
        _ -> case whereis(?MODULE) of
            undefined -> configured_suite();
            Run -> Run
        end
    end.

configured_suite() ->
    case persistent_term:get({?MODULE, suite_owner}, undefined) of
        Owner when is_pid(Owner) ->
            case is_process_alive(Owner) of
                true -> case gen_server:start({local, ?MODULE}, ?MODULE, Owner, []) of
                    {ok, Run} -> Run;
                    {error, {already_started, Run}} -> Run
                end;
                false -> error({lawspec, missing_resource_run})
            end;
        _ -> error({lawspec, missing_resource_run})
    end.

with_shared(Key, Schema, Acquire, Reset, Release, Concurrent, Body) ->
    {Value, Lease} = checkout(current(), Key, Schema, Acquire, Reset, Release, Concurrent),
    try Body(Value) after checkin(Lease) end.

%% Each assertion (including shrinks) gets a fresh owner. The enclosing test
%% supervisor keeps this registry alive after cancelling its borrower. Entries
%% retire after normal release, so a long property does not retain old values.
with_resource(Schema, Acquire, Release, Body) ->
    case get({?MODULE, case_run}) of
        undefined ->
            {ok, Run} = start(),
            try with_case_run(Run, fun() -> with_resource(Schema, Acquire, Release, Body) end)
            after close(Run) end;
        Run ->
            Key = make_ref(),
            {ok, Entry} = gen_server:call(Run, {entry, Key, false}, infinity),
            try
                {Value, Lease} = lawspec_beam_resource:checkout(Entry, Schema,
                    lawspec_beam_runtime:worker_context(), Acquire, fun(_) -> ok end, Release),
                try Body(Value) after checkin(Lease) end
            after
                try lawspec_beam_resource:close(Entry)
                catch Class:Reason:Stack ->
                    lawspec_beam_harness:mark_harness_failure(Reason),
                    erlang:raise(Class, Reason, Stack)
                end
            end
    end.

checkout(Run, Key, Schema, Acquire, Reset, Release, Concurrent) ->
    case gen_server:call(Run, {entry, Key, Concurrent}, infinity) of
        {ok, Entry} -> lawspec_beam_resource:checkout(Entry, Schema,
            lawspec_beam_runtime:worker_context(), Acquire, Reset, Release);
        {error, Reason} -> error({lawspec, Reason})
    end.
checkin(Lease) -> lawspec_beam_resource:checkin(Lease).

close(Run) ->
    Monitor = monitor(process, Run),
    try gen_server:call(Run, close, infinity) of
        Result ->
            receive {'DOWN', Monitor, process, Run, _} -> ok end,
            case Result of
                ok -> ok;
                {error, Errors} -> error({lawspec, {resource_cleanup_failed, Errors}})
            end
    catch exit:{noproc, _} -> ok; exit:{normal, _} -> ok
    after demonitor(Monitor, [flush]) end.

init(Owner) when is_pid(Owner) -> init({Owner, 5000});
init({Owner, CleanupTimeout}) ->
    {ok, #{owner => monitor(process, Owner), entries => #{}, monitors => #{},
        workers => #{}, closing => false, waiters => [], cleanup => none,
        cleanup_result => none, failures => [], cleanup_timeout => CleanupTimeout,
        timer => none, cleanup_pid => none, cases => #{}}}.

handle_call(watch_case, _, State = #{closing := true}) ->
    {reply, {error, resource_run_closed}, State};
handle_call(watch_case, {Supervisor, _}, State = #{cases := Cases}) ->
    {reply, ok, State#{cases := Cases#{monitor(process, Supervisor) => Supervisor}}};
handle_call({case_finished, Result}, {Supervisor, _}, State = #{cases := Cases}) ->
    Rest = maps:filter(fun(Ref, Pid) ->
        case Pid =:= Supervisor of true -> demonitor(Ref, [flush]), false; false -> true end
    end, Cases),
    Failures = case Result of {ok, ok} -> maps:get(failures, State); _ -> [{case_cleanup, Result} | maps:get(failures, State)] end,
    {reply, ok, maybe_cleanup(State#{cases := Rest, failures := Failures})};

%% Register before any callback begins. If its lease coordinator dies, a
%% worker still releases its value; the run must join that release as well.
handle_call({resource_worker, Key}, {Worker, _}, State = #{workers := Workers}) ->
    Monitor = monitor(process, Worker),
    {reply, ok, State#{workers := Workers#{Monitor => {Key, Worker}}}};
handle_call({entry, _, _}, _, State = #{closing := true}) ->
    {reply, {error, resource_run_closed}, State};
handle_call({entry, Key, Concurrent}, _, State = #{entries := Entries, monitors := Monitors}) ->
    case maps:find(Key, Entries) of
        {ok, {Entry, Concurrent}} -> {reply, {ok, Entry}, State};
        {ok, _} -> {reply, {error, {resource_concurrency_mismatch, Key}}, State};
        error ->
            {ok, Entry} = lawspec_beam_resource:start(self(), Key, Concurrent, maps:get(cleanup_timeout, State)),
            Monitor = monitor(process, Entry),
            {reply, {ok, Entry}, State#{entries := Entries#{Key => {Entry, Concurrent}},
                monitors := Monitors#{Monitor => Key}}}
    end;
handle_call(close, From, State = #{waiters := Waiters}) ->
    {noreply, begin_close(State#{waiters := [From | Waiters]})}.

handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Owner, process, _, _}, State = #{owner := Owner}) ->
    {noreply, begin_close(State)};
handle_info({'DOWN', Monitor, process, _, _}, State = #{workers := Workers}) when is_map_key(Monitor, Workers) ->
    finish_close(State#{workers := maps:remove(Monitor, Workers)});
handle_info({'DOWN', Monitor, process, _, Reason}, State = #{cases := Cases}) when is_map_key(Monitor, Cases) ->
    Updated = State#{cases := maps:remove(Monitor, Cases),
        failures := [{case_supervisor_failed, Reason} | maps:get(failures, State)]},
    {noreply, maybe_cleanup(Updated)};
handle_info({'DOWN', Monitor, process, _, {resource_cleanup, Result}}, State = #{cleanup := Monitor}) ->
    finish_close(State#{cleanup := none, cleanup_result := Result});
handle_info({'DOWN', Monitor, process, _, Reason}, State = #{cleanup := Monitor}) ->
    force_close({cleanup_worker, Reason}, State);
handle_info({timeout, Timer, cleanup}, State = #{timer := Timer}) ->
    force_close(resource_run_cleanup_timeout, State#{timer := none});
handle_info({resource_finished, Key, Entry, Result}, State = #{entries := Entries, monitors := Monitors}) ->
    case maps:find(Key, Entries) of
        {ok, {Entry, _}} ->
            Rest = maps:filter(fun(Monitor, Name) ->
                case Name =:= Key of true -> demonitor(Monitor, [flush]), false; false -> true end
            end, Monitors),
            Failures = case Result of
                {ok, ok} -> maps:get(failures, State);
                Failure -> [{Key, Failure} | maps:get(failures, State)]
            end,
            finish_close(State#{entries := maps:remove(Key, Entries), monitors := Rest, failures := Failures});
        _ -> {noreply, State}
    end;
handle_info({'DOWN', Monitor, process, _, Reason}, State = #{monitors := Monitors, closing := Closing}) ->
    case maps:take(Monitor, Monitors) of
        {Key, Rest} ->
            Failures = case Closing andalso Reason =:= normal of
                true -> maps:get(failures, State);
                false -> [{Key, {resource_owner_failed, Reason}} | maps:get(failures, State)]
            end,
            finish_close(State#{entries := maps:remove(Key, maps:get(entries, State)), monitors := Rest, failures := Failures});
        error -> {noreply, State}
    end;
handle_info(_, State) -> {noreply, State}.

begin_close(#{closing := true} = State) -> State;
begin_close(State = #{cases := Cases}) ->
    maps:foreach(fun(_, Pid) -> Pid ! close_case end, Cases),
    maybe_cleanup(State#{closing := true}).

maybe_cleanup(#{closing := true, cleanup := none, cleanup_result := none, cases := Cases, entries := Entries} = State)
        when map_size(Cases) =:= 0 ->
    {Pid, Monitor} = spawn_monitor(fun() -> exit({resource_cleanup, cleanup(maps:to_list(Entries))}) end),
    %% Entry drain and release have separate deadlines. This outer deadline
    %% also bounds orphan owners if a lease coordinator has crashed.
    Budget = 1000 + 2 * max(1, map_size(Entries)) * maps:get(cleanup_timeout, State),
    State#{closing := true, cleanup := Monitor, cleanup_pid := Pid,
        timer := erlang:start_timer(Budget, self(), cleanup)};
maybe_cleanup(State) -> State.

force_close(Reason, State) ->
    maps:foreach(fun(_, {Entry, _}) -> exit(Entry, kill) end, maps:get(entries, State)),
    maps:foreach(fun(_, {_, Worker}) -> exit(Worker, kill) end, maps:get(workers, State)),
    case maps:get(cleanup_pid, State) of none -> ok; Pid -> exit(Pid, kill) end,
    case maps:get(cleanup, State) of none -> ok; Ref -> demonitor(Ref, [flush]) end,
    finish_close(State#{cleanup := none, cleanup_result := [Reason]}).

finish_close(#{cleanup_result := Result, workers := Workers, monitors := Monitors} = State)
        when Result =/= none, map_size(Workers) =:= 0, map_size(Monitors) =:= 0 ->
    Errors = lists:usort(maps:get(failures, State) ++ Result),
    Reply = case Errors of [] -> ok; _ -> {error, Errors} end,
    lists:foreach(fun(From) -> gen_server:reply(From, Reply) end, maps:get(waiters, State)),
    case maps:get(timer, State) of none -> ok; Timer -> erlang:cancel_timer(Timer) end,
    {stop, normal, State};
finish_close(State) -> {noreply, State}.

cleanup(Entries) ->
    Frozen = [{Key, Entry, capture(fun() -> lawspec_beam_resource:freeze(Entry) end)}
        || {Key, {Entry, _}} <- Entries],
    Ordered = lists:sort(fun({_, _, A}, {_, _, B}) -> order(A) > order(B) end, Frozen),
    lists:append([case FrozenResult of
        {ok, _} -> case capture(fun() -> lawspec_beam_resource:close(Entry) end) of
            {ok, ok} -> [];
            Failure -> cleanup_failure(Key, Failure)
        end;
        Failure -> cleanup_failure(Key, Failure)
    end || {Key, Entry, FrozenResult} <- Ordered]).
%% An entry can finish a bracket while the run begins closing. Its result is
%% recorded by the registry before its monitor is removed, including failures.
cleanup_failure(_, {exception, exit, {noproc, _}, _}) -> [];
cleanup_failure(_, {exception, exit, {normal, _}, _}) -> [];
cleanup_failure(Key, Failure) -> [{Key, Failure}].
order({ok, {acquired, Number}}) -> Number;
order(_) -> 0.
capture(Body) -> try {ok, Body()} catch Class:Reason:Stack -> {exception, Class, Reason, Stack} end.

%% If the registry itself is stopped unexpectedly, every entry monitors it
%% and completes its own draining and release path.
terminate(_, _) -> ok.
