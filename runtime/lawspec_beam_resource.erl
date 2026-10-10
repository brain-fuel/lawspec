%% @doc A shared resource has one stable callback process and monitored users.
%% Acquisition, reset and release keep their original ability and policy
%% context; callbacks never run inside the responsive lease coordinator.
%% ref:REQ-law-primitives ref:REQ-harness-units
-module(lawspec_beam_resource).
-behaviour(gen_server).
-export([start/3, start/4, checkout/6, checkin/1, freeze/1, close/1, call/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start(Run, Key, Concurrent) -> start(Run, Key, Concurrent, 5000).
start(Run, Key, Concurrent, CleanupTimeout) ->
    gen_server:start(?MODULE, {Run, Key, Concurrent, CleanupTimeout}, []).
%% A native adapter can save private state in its process dictionary, return
%% self() from acquire and route operations here. Process-owned state stays put.
call(Owner, Body) when Owner =:= self() -> Body();
call(Owner, Body) -> unwrap(gen_server:call(Owner, {resource_call, Body}, infinity)).
checkout(Entry, Schema, Context, Acquire, Reset, Release) ->
    unwrap(gen_server:call(Entry, {checkout, Schema, Context, Acquire, Reset, Release}, infinity)).
checkin({Entry, Token}) -> unwrap(gen_server:call(Entry, {checkin, Token}, infinity)).
freeze(Entry) -> unwrap(gen_server:call(Entry, freeze, infinity)).
close(Entry) ->
    Monitor = monitor(process, Entry),
    try gen_server:call(Entry, close, infinity) of
        Result -> receive {'DOWN', Monitor, process, Entry, _} -> unwrap(Result) end
    after demonitor(Monitor, [flush]) end.

unwrap({ok, Value}) -> Value;
unwrap({exception, Class, Reason, Stack}) -> erlang:raise(Class, Reason, Stack).
failure(Reason) -> {exception, error, {lawspec, Reason}, []}.

init({Run, Key, Concurrent, CleanupTimeout}) ->
    {ok, #{run => monitor(process, Run), run_pid => Run, key => Key, concurrent => Concurrent,
        worker => none, pending => none, value => none, acquired => none,
        leases => #{}, waiting => queue:new(), frozen => false, freeze_waiters => [],
        closing => false, close_waiters => [], failure => none,
        cleanup_timeout => CleanupTimeout, timer => none}}.

handle_call({checkout, _, _, _, _, _}, _, State = #{frozen := true}) ->
    {reply, failure(resource_run_closed), State};
handle_call({checkout, Schema, Context, Acquire, Reset, Release}, From = {Owner, _}, State) ->
    Token = monitor(process, Owner),
    Request = {From, Token, {Schema, Context, Acquire, Reset, Release}},
    Waiting = maps:get(waiting, State),
    Leases = maps:get(leases, State),
    case maps:get(pending, State) =:= none andalso map_size(Leases) > 0 andalso
            lists:all(fun(HeldBy) -> HeldBy =:= Owner end, maps:values(Leases)) of
        true -> {noreply, grant(Request, State)};
        false -> advance(State#{waiting := queue:in(Request, Waiting)})
    end;
handle_call({checkin, Token}, {Owner, _}, State = #{leases := Leases}) ->
    case maps:find(Token, Leases) of
        {ok, Owner} ->
            demonitor(Token, [flush]),
            case advance(State#{leases := maps:remove(Token, Leases)}) of
                {noreply, Updated} -> {reply, {ok, ok}, Updated};
                {stop, Reason, Updated} -> {stop, Reason, {ok, ok}, Updated}
            end;
        _ -> {reply, failure(invalid_resource_lease), State}
    end;
handle_call(freeze, From, State = #{freeze_waiters := Waiters}) ->
    advance(freeze_state(State#{freeze_waiters := [From | Waiters]}));
handle_call(close, From, State = #{close_waiters := Waiters}) ->
    advance(freeze_state(State#{closing := true, close_waiters := [From | Waiters]})).

handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Run, process, _, _}, State = #{run := Run}) ->
    advance(freeze_state(State#{closing := true}));
handle_info({resource_ready, Worker, Value, Number}, State = #{worker := {Worker, _}, pending := {acquire, Request}}) ->
    advance(grant(Request, State#{pending := none, value := {some, Value}, acquired := Number}));
handle_info({resource_reset, Worker, Result}, State = #{worker := {Worker, _}, pending := {reset, Request}}) ->
    Updated = case Result of
        {ok, _} -> grant(Request, State#{pending := none});
        Failure -> reject(Request, Failure), State#{pending := none}
    end,
    advance(Updated);
handle_info({'DOWN', Monitor, process, Worker, Reason}, State = #{worker := {Worker, Monitor}}) ->
    worker_stopped(Reason, State#{worker := none});
handle_info({timeout, Timer, cleanup}, State = #{timer := Timer}) ->
    Failure = failure({resource_cleanup_timeout, maps:get(key, State),
        maps:get(cleanup_timeout, State)}),
    case maps:get(pending, State) of {_, Request} -> reject(Request, Failure); _ -> ok end,
    case maps:get(worker, State) of {Worker, _} -> exit(Worker, kill); none -> ok end,
    lists:foreach(fun(From) -> gen_server:reply(From, Failure) end, maps:get(freeze_waiters, State)),
    %% Join the owner before reporting completion. Its retained effect/workflow
    %% scopes also monitor it, so forced cleanup cannot leave a live lease.
    Updated = State#{pending := none, failure := Failure, timer := none,
        leases := #{}, freeze_waiters := [], closing := true},
    case maps:get(worker, Updated) of none -> finished(Updated); _ -> {noreply, Updated} end;
handle_info({'DOWN', Token, process, _, _}, State = #{leases := Leases, waiting := Waiting}) ->
    advance(State#{leases := maps:remove(Token, Leases),
        waiting := queue:filter(fun({_, T, _}) -> T =/= Token end, Waiting)});
handle_info(_, State) -> {noreply, State}.

freeze_state(#{frozen := true} = State) -> State;
freeze_state(#{waiting := Waiting} = State) ->
    lists:foreach(fun(Request) -> reject(Request, failure(resource_run_closed)) end, queue:to_list(Waiting)),
    arm(State#{frozen := true, waiting := queue:new()}).

arm(#{timer := none, cleanup_timeout := Milliseconds} = State) ->
    State#{timer := erlang:start_timer(Milliseconds, self(), cleanup)};
arm(State) -> State.
disarm(#{timer := none} = State) -> State;
disarm(#{timer := Timer} = State) -> erlang:cancel_timer(Timer), State#{timer := none}.

advance(#{pending := Pending} = State) when Pending =/= none -> {noreply, State};
advance(#{frozen := true, leases := Leases} = State) when map_size(Leases) > 0 -> {noreply, State};
advance(#{frozen := true, acquired := Acquired, freeze_waiters := Waiters, closing := Closing} = State) ->
    Reply = case Acquired of none -> none; _ -> {acquired, Acquired} end,
    lists:foreach(fun(From) -> gen_server:reply(From, {ok, Reply}) end, Waiters),
    Ready = disarm(State#{freeze_waiters := []}),
    case {Closing, maps:get(worker, Ready)} of
        {false, _} -> {noreply, Ready};
        {true, {Worker, _}} -> Worker ! release, {noreply, arm(Ready#{pending := release})};
        {true, none} -> finished(Ready)
    end;
advance(#{waiting := Waiting} = State) ->
    case queue:out(Waiting) of
        {empty, _} -> {noreply, State};
        {{value, Request = {{Owner, _}, _, _}}, Rest} ->
            Leases = maps:get(leases, State),
            Available = map_size(Leases) =:= 0 orelse maps:get(concurrent, State) orelse
                lists:all(fun(HeldBy) -> HeldBy =:= Owner end, maps:values(Leases)),
            case is_process_alive(Owner) of
                false -> reject(Request, failure(resource_caller_stopped)), advance(State#{waiting := Rest});
                true when not Available -> {noreply, State};
                true -> begin_use(Request, State#{waiting := Rest})
            end
    end.

begin_use(Request = {_, _, Spec}, State = #{worker := none, failure := none, run_pid := Run, key := Key}) ->
    Entry = self(),
    {Worker, Monitor} = spawn_monitor(fun() -> resource_worker(Run, Entry, Key, Spec) end),
    {noreply, State#{worker := {Worker, Monitor}, pending := {acquire, Request}}};
begin_use(Request, State = #{failure := Failure}) when Failure =/= none ->
    reject(Request, Failure), advance(State);
begin_use(Request, State = #{worker := {Worker, _}, leases := Leases}) when map_size(Leases) =:= 0 ->
    Worker ! reset,
    {noreply, State#{pending := {reset, Request}}};
begin_use(Request, State) -> advance(grant(Request, State)).

grant(Request = {From = {Owner, _}, Token, _}, State = #{frozen := Frozen, value := {some, Value}, leases := Leases}) ->
    case not Frozen andalso is_process_alive(Owner) of
        true -> gen_server:reply(From, {ok, {Value, {self(), Token}}}), State#{leases := Leases#{Token => Owner}};
        false -> reject(Request, failure(resource_run_closed)), State
    end.
reject({From, Token, _}, Result) -> demonitor(Token, [flush]), gen_server:reply(From, Result).

worker_stopped({resource_acquisition_failed, Failure}, State = #{pending := {acquire, Request}}) ->
    reject(Request, Failure), advance(State#{pending := none});
worker_stopped({resource_released, Result}, State = #{pending := release}) ->
    Failure = case Result of {ok, _} -> maps:get(failure, State); _ -> Result end,
    finished(State#{pending := none, failure := Failure});
worker_stopped(Reason, State) ->
    Failure = case maps:get(failure, State) of
        none -> failure({resource_worker_failed, maps:get(key, State), Reason});
        Existing -> Existing
    end,
    case maps:get(pending, State) of
        {_, Request} -> reject(Request, Failure);
        _ -> ok
    end,
    advance(State#{pending := none, failure := Failure}).

finished(State = #{close_waiters := Waiters, failure := Failure}) ->
    Reply = case Failure of none -> {ok, ok}; _ -> Failure end,
    maps:get(run_pid, State) ! {resource_finished, maps:get(key, State), self(), Reply},
    lists:foreach(fun(From) -> gen_server:reply(From, Reply) end, Waiters),
    {stop, normal, disarm(State)}.

resource_worker(Run, Entry, Key, Spec) ->
    Result = try
        ok = gen_server:call(Run, {resource_worker, Key}, infinity),
        retained_worker(Entry, Spec)
        catch Class:Reason:Stack -> {resource_acquisition_failed, {exception, Class, Reason, Stack}} end,
    exit(Result).

retained_worker(Entry, {Schema, Context, Acquire, Reset, Release}) ->
    Owner = monitor(process, Entry),
    %% Programs with pure resource callbacks do not emit the ability runtime.
    Effects = case maps:is_key(lawspec_scope, Schema) orelse maps:is_key(lawspec_scopes, Schema) of
        true -> lawspec_beam_effects:retain(Schema, self());
        false -> []
    end,
    try
        Workflow = case proplists:get_value({lawspec_beam_workflow, runtime}, Context) of
            #{state := Pid} -> [lawspec_beam_workflow_state:retain(Pid, self())];
            _ -> []
        end,
        try
            %% Case cancellation scopes and active handler operations end with
            %% that case. The resource worker owns its own nested operations.
            Detached = [{Key, case Key of
                {lawspec_beam_tasks, scopes} -> undefined;
                {lawspec_beam_handler, context} -> undefined;
                {lawspec_beam_workflow, frame} -> undefined;
                {lawspec_beam_resources, case_run} -> undefined;
                _ -> Value
            end} || {Key, Value} <- Context],
            lawspec_beam_runtime:with_worker_context(Detached, fun() ->
                case capture(Acquire) of
                    {ok, Value} ->
                        Entry ! {resource_ready, self(), Value, erlang:unique_integer([positive, monotonic])},
                        Loop = capture(fun() -> worker_loop(Entry, Owner, Value, Reset) end),
                        Released = capture(fun() -> Release(Value) end),
                        {resource_released, case Loop of {ok, _} -> Released; _ -> Loop end};
                    Failure -> {resource_acquisition_failed, Failure}
                end
            end)
        after lists:foreach(fun lawspec_beam_workflow_state:release/1, Workflow) end
    after case Effects of [] -> ok; _ -> lawspec_beam_effects:release(Effects) end end.

worker_loop(Entry, Owner, Value, Reset) ->
    receive
        {'$gen_call', From, {resource_call, Body}} ->
            gen_server:reply(From, capture(Body)),
            worker_loop(Entry, Owner, Value, Reset);
        reset ->
            Entry ! {resource_reset, self(), capture(fun() -> Reset(Value) end)},
            worker_loop(Entry, Owner, Value, Reset);
        release -> ok;
        {'DOWN', Owner, process, Entry, _} -> ok
    end.
capture(Body) -> try {ok, Body()} catch Class:Reason:Stack -> {exception, Class, Reason, Stack} end.
