%% @doc One spec handler's state, shared by all processes in its scope.
%% Clauses run outside the server so a blocked clause can still be cancelled.
%% ref:DEC-typed-core-boundary
-module(lawspec_beam_handler).
-behaviour(gen_server).
-export([start/2, call/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start(Owner, Initial) -> gen_server:start(?MODULE, {Owner, Initial}, []).

call(Handler, Update) ->
    case gen_server:call(Handler, {update, Update}, infinity) of
        {ok, Value} -> Value;
        {exception, Class, Reason, Stack} -> erlang:raise(Class, Reason, Stack)
    end.

stop(Handler) ->
    try gen_server:stop(Handler, normal, infinity)
    catch exit:noproc -> ok end.

init({Owner, Initial}) ->
    process_flag(trap_exit, true),
    {ok, #{owner => monitor(process, Owner), value => Initial,
        active => none, waiting => queue:new()}}.

handle_call({update, Update}, From = {Caller, _}, State) ->
    Entry = {From, monitor(process, Caller), Update},
    {noreply, next(State#{waiting := queue:in(Entry, maps:get(waiting, State))})}.

handle_cast(_, State) -> {noreply, State}.

handle_info({'DOWN', Owner, process, _, _}, State = #{owner := Owner}) ->
    {stop, normal, State};
handle_info({'DOWN', Monitor, process, Pid, Reason},
        State = #{active := {Pid, Monitor, From, CallerMonitor}}) ->
    demonitor(CallerMonitor, [flush]),
    %% A cancelled caller cannot commit a half-finished operation. Its DOWN
    %% signal may still be behind the worker's result in the mailbox.
    Updated = case is_process_alive(element(1, From)) of
        false -> State;
        true -> case Reason of
            {lawspec_result, {ok, Value, NewState}} ->
                gen_server:reply(From, {ok, Value}), State#{value := NewState};
            {lawspec_result, {exception, _, _, _} = Failure} ->
                gen_server:reply(From, Failure), State;
            _ ->
                gen_server:reply(From, {exception, error,
                    {lawspec, {handler_worker_failed, Reason}}, []}), State
        end
    end,
    {noreply, next(Updated#{active := none})};
handle_info({'DOWN', CallerMonitor, process, _, _},
        State = #{active := {Pid, Monitor, _, CallerMonitor}}) ->
    cancel(Pid, Monitor),
    {noreply, next(State#{active := none})};
handle_info({'DOWN', Monitor, process, _, _}, State) ->
    Waiting = queue:filter(fun({_, M, _}) -> M =/= Monitor end, maps:get(waiting, State)),
    {noreply, State#{waiting := Waiting}};
handle_info(_, State) -> {noreply, State}.

terminate(_, State) ->
    case maps:get(active, State) of
        none -> ok;
        {Pid, Monitor, _, CallerMonitor} ->
            cancel(Pid, Monitor), demonitor(CallerMonitor, [flush])
    end,
    lists:foreach(fun({_, M, _}) -> demonitor(M, [flush]) end,
        queue:to_list(maps:get(waiting, State))).

next(State = #{active := none, waiting := Waiting, value := Value}) ->
    case queue:out(Waiting) of
        {empty, _} -> State;
        {{value, {From, CallerMonitor, Update}}, Rest} ->
            case is_process_alive(element(1, From)) of
                false -> demonitor(CallerMonitor, [flush]), next(State#{waiting := Rest});
                true ->
                    %% The link prevents a worker leaking if the server itself
                    %% is killed; the monitor carries its result and stack.
                    {Pid, Monitor} = spawn_opt(fun() ->
                        Result = try
                            case Update(Value) of
                                {Reply, NewState} -> {ok, Reply, NewState};
                                Other -> erlang:error({lawspec, {invalid_handler_result, Other}})
                            end
                        catch Class:Reason:Stack -> {exception, Class, Reason, Stack} end,
                        exit({lawspec_result, Result})
                    end, [link, monitor]),
                    State#{active := {Pid, Monitor, From, CallerMonitor}, waiting := Rest}
            end
    end;
next(State) -> State.

cancel(Pid, Monitor) ->
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, _} -> ok end.
