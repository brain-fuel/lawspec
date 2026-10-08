%% @doc One actor's state-owning gen_server. A successful handler commits its
%% checkpoint before replying; an exception never commits a partial state.
%% ref:DEC-actors-otp-supervision
-module(lawspec_beam_actor).
-behaviour(gen_server).
-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link(Tree, Id) -> gen_server:start_link(?MODULE, {Tree, Id, self()}, []).

init({Tree, Id, Parent}) ->
    process_flag(trap_exit, true),
    Worker = self(),
    Guard = spawn(fun() -> guard(Tree, Parent, Worker) end),
    receive {Guard, ready} -> ok end,
    case gen_server:call(Tree, {actor_started, Id, self()}, infinity) of
        stopped -> ignore;
        {ok, Spec, Checkpoint} ->
            try
                Initial = scoped(Tree, Id, fun() -> lawspec_beam_runtime:with_worker_context(maps:get(context, Spec), fun() ->
                    case Checkpoint of
                        none -> (maps:get(start, Spec))();
                        {resume, Previous} -> Previous;
                        {some, Previous} -> (maps:get(restart, Spec))(Previous)
                    end
                end) end),
                ok = gen_server:call(Tree, {ready, Id, self(), Initial}, infinity),
                {ok, #{tree => Tree, id => Id, value => Initial, spec => Spec, guard => Guard}}
            catch Class:Reason:Stack ->
                gen_server:call(Tree, {start_failed, Id, self(), {Class, Reason, Stack}}, infinity),
                {stop, {actor_start_failed, Class, Reason}}
            end
    end.

handle_call(_, _, State) -> {reply, {error, unsupported}, State}.
handle_cast(_, State) -> {noreply, State}.

handle_info({deliver, Token, Operation}, State = #{tree := Tree, id := Id, value := Value}) ->
    case gen_server:call(Tree, {begin_message, Id, self(), Token}, infinity) of
        false -> {noreply, State};
        true -> execute(Operation, Token, Value, State)
    end;
handle_info(_, State) -> {noreply, State}.

execute({handler, Handler, Context}, Token, Value, State = #{tree := Tree, id := Id}) ->
    Result = try
        case scoped(Tree, Id, fun() -> lawspec_beam_runtime:with_worker_context(Context, fun() -> Handler(Value) end) end) of
            {Reply, Next} -> {ok, Reply, Next};
            Other -> error({lawspec, {invalid_actor_handler_result, Other}})
        end
    catch Class:Reason:Stack -> {exception, {Class, Reason, Stack}} end,
    case Result of
        {ok, ReplyValue, NextValue} ->
            ok = gen_server:call(Tree, {commit, Id, self(), Token, ReplyValue, NextValue}, infinity),
            {noreply, State#{value := NextValue}};
        {exception, Failure} -> fail(Token, Failure, make_ref(), State)
    end;
execute({crash, Cause, Origin}, Token, _, State) -> fail(Token, Cause, Origin, State);
execute(restart, Token, Value, State = #{spec := Spec}) ->
    Handler = fun(Previous) -> {ok, (maps:get(restart, Spec))(Previous)} end,
    execute({handler, Handler, maps:get(context, Spec)}, Token, Value, State);
execute(stop, Token, _, State = #{tree := Tree, id := Id}) ->
    Action = gen_server:call(Tree, {worker_stopped, Id, self(), Token}, infinity),
    finish(Action, normal, State).

fail(Token, Cause, Origin, State = #{tree := Tree, id := Id}) ->
    Action = gen_server:call(Tree, {failed, Id, self(), Token, Cause, Origin}, infinity),
    finish(Action, {actor_crashed, Cause}, State).

finish(wait, _, State) -> {noreply, State};
finish(exit, Reason, State) -> {stop, Reason, State}.

%% Each operation owns its nested async workers. The stable service joins
%% this scope on worker death before allowing a replacement to run.
scoped(Tree, Id, Body) -> lawspec_beam_tasks:with_scope(fun(Scope) ->
    case gen_server:call(Tree, {scope, Id, self(), Scope}, infinity) of
        ok -> Body();
        stopped -> exit(shutdown)
    end
end).

%% A killed supervisor cannot enforce its own shutdown timeout. A separate
%% monitor keeps that bound even while a native handler or init callback is
%% blocked. It never executes application code and ends with its worker.
guard(Tree, Parent, Worker) ->
    WorkerMonitor = erlang:monitor(process, Worker),
    TreeMonitor = erlang:monitor(process, Tree),
    ParentMonitor = erlang:monitor(process, Parent),
    Worker ! {self(), ready},
    receive
        {'DOWN', WorkerMonitor, process, Worker, _} -> ok;
        {'DOWN', Monitor, process, _, _} when Monitor =:= TreeMonitor; Monitor =:= ParentMonitor ->
            receive
                {'DOWN', WorkerMonitor, process, Worker, _} -> ok
            after 5000 ->
                exit(Worker, kill),
                receive {'DOWN', WorkerMonitor, process, Worker, _} -> ok end
            end
    end.
