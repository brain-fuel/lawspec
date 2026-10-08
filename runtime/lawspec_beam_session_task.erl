%% @doc A native session task takes an end before running its callback.
%% The caller owns the task until join; cancellation joins the worker and
%% its owned ends fail, while any ends it delegated keep their new owner.
%% ref:DEC-sessions-by-construction ref:DEC-async-native-tasks
-module(lawspec_beam_session_task).
-behaviour(gen_server).
-export([start/2, join/1, stop/1, cancel/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export_type([task/0]).
-opaque task() :: pid().

start(End, Body) when is_function(Body, 1) ->
    Context = lawspec_beam_runtime:worker_context(),
    case gen_server:start(?MODULE, {self(), Context, End, Body}, []) of
        {ok, Task} -> Task;
        {error, {exception, Class, Reason, Stack}} -> erlang:raise(Class, Reason, Stack);
        {error, Reason} -> error({lawspec, {session_task_start, Reason}})
    end.
join(Task) ->
    Monitor = monitor(process, Task),
    Result = try gen_server:call(Task, join, infinity)
        catch exit:{_, {gen_server, call, [Task, _, infinity]}} ->
            {exception, error, {lawspec, session_task_closed}, []} end,
    %% A waiting joiner is replied to from handle_info before terminate runs.
    %% Await termination too, so scope cleanup has finished on return.
    receive {'DOWN', Monitor, process, Task, _} -> ok end,
    case Result of
        {ok, Value} -> Value;
        {exception, Class, Reason, Stack} -> erlang:raise(Class, Reason, Stack)
    end.
stop(Task) ->
    try gen_server:stop(Task, normal, infinity)
    catch exit:noproc -> ok; exit:{noproc, _} -> ok; exit:{normal, _} -> ok end.
cancel(Task) -> stop(Task), nil.

init({Caller, Context, End, Body}) ->
    process_flag(trap_exit, true),
    Scope = lawspec_beam_tasks:open(),
    Parents = case proplists:get_value({lawspec_beam_tasks, scopes}, Context) of undefined -> []; Given -> Given end,
    WorkerContext = lists:keystore({lawspec_beam_tasks, scopes}, 1, Context, {{lawspec_beam_tasks, scopes}, [Scope | Parents]}),
    {Worker, Ref} = spawn_opt(fun() ->
        receive {start, Owned} ->
            Result = try {ok, lawspec_beam_runtime:with_worker_context(WorkerContext, fun() ->
                lawspec_beam_session:with_owned([Owned], fun() -> Body(Owned) end)
            end)} catch Class:Reason:Stack -> {exception, Class, Reason, Stack} end,
            exit({lawspec_session_result, Result})
        end
    end, [link, monitor]),
    try
        %% The task itself is also in the surrounding cancellation scopes.
        lawspec_beam_runtime:with_worker_context(Context, fun() -> ok end),
        ok = lawspec_beam_tasks:adopt(Scope, Worker),
        Owned = lawspec_beam_session:transfer_to_task(End, Worker),
        Worker ! {start, Owned},
        {ok, #{worker => Worker, worker_monitor => Ref, caller => monitor(process, Caller), scope => Scope,
            outcome => pending, waiters => []}}
    catch Class:Reason:Stack ->
        exit(Worker, kill), lawspec_beam_tasks:close(Scope), receive {'DOWN', Ref, process, Worker, _} -> ok end,
        {stop, {exception, Class, Reason, Stack}}
    end.
handle_call(join, From, State = #{outcome := pending, waiters := Waiters}) ->
    {noreply, State#{waiters := [From | Waiters]}};
handle_call(join, _, State = #{outcome := Outcome}) -> {stop, normal, Outcome, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Ref, process, _, Reason}, State = #{worker_monitor := Ref, waiters := Waiters}) ->
    Outcome = case Reason of
        {lawspec_session_result, Result} -> Result;
        _ -> {exception, error, {lawspec, {session_task_failed, Reason}}, []}
    end,
    Updated = State#{outcome := Outcome, worker_monitor := none},
    case Waiters of
        [] -> {noreply, Updated};
        _ -> lists:foreach(fun(From) -> gen_server:reply(From, Outcome) end, Waiters),
            {stop, normal, Updated#{waiters := []}}
    end;
handle_info({'DOWN', Ref, process, _, _}, State = #{caller := Ref}) -> {stop, normal, State};
handle_info(_, State) -> {noreply, State}.
terminate(_, #{worker := Worker, worker_monitor := Ref, waiters := Waiters, scope := Scope}) ->
    lawspec_beam_tasks:close(Scope),
    case Ref of
        none -> ok;
        _ -> exit(Worker, kill), receive {'DOWN', Ref, process, Worker, _} -> ok end
    end,
    lists:foreach(fun(From) -> gen_server:reply(From, {exception, error, {lawspec, session_task_closed}, []}) end, Waiters).
