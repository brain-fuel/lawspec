%% @doc A scenario's channels, delegated ends and mailbox send obligations
%% have one owner. A single server transfers them atomically and never runs
%% application code. Process death releases both current and unforked work.
%% ref:DEC-sessions-by-construction
-module(lawspec_beam_scenario_io).
-behaviour(gen_server).
-export([start/2, with_io/3, stop/1, fork/3, enter/2, leave/2,
    send/5, receive_value/3, receive_value/4, abandon/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start(Channels, Mailboxes) -> gen_server:start(?MODULE, {self(), Channels, Mailboxes}, []).
with_io(Channels, Mailboxes, Body) ->
    {ok, Hub} = start(Channels, Mailboxes),
    try Body(Hub) after stop(Hub) end.
stop(Hub) ->
    try gen_server:stop(Hub, normal, infinity)
    catch exit:noproc -> ok; exit:{noproc, _} -> ok end.
fork(Hub, Parent, Children) -> call(Hub, {fork, Parent, Children}).
enter(Hub, Identity) -> call(Hub, {enter, Identity}).
leave(Hub, Identity) -> call(Hub, {leave, Identity}).
send(Hub, Identity, Destination, Value, Clock) -> call(Hub, {send, Identity, Destination, Value, Clock}).
receive_value(Hub, Identity, Destination) -> receive_value(Hub, Identity, Destination, 5000).
receive_value(Hub, Identity, Destination, Timeout) -> call(Hub, {'receive', Identity, Destination, Timeout}).
abandon(Hub, Identity, End) -> call(Hub, {abandon, Identity, End}).
call(Hub, Request) ->
    case gen_server:call(Hub, Request, infinity) of
        {error, Reason} -> error({lawspec, {scenario_io, Reason}});
        Result -> Result
    end.

%% Ends are {end, Name, Side}; mailboxes are {mailbox, Name}. A payload
%% {lawspec_scenario_end, Name, Side} moves ownership, rather than copying it.
init({Owner, Channels, Mailboxes}) ->
    Ends = maps:from_list([{{'end', Name, Side}, queue_state(root)} || Name <- Channels, Side <- [0, 1]]),
    Boxes = maps:from_list([{{mailbox, Name}, (queue_state(root))#{outstanding => Count}}
        || {Name, Count} <- maps:to_list(Mailboxes)]),
    {ok, #{owner => monitor(process, Owner), queues => maps:merge(Ends, Boxes), monitors => #{},
        processes => #{root => #{pid => Owner, monitor => none, parent => none, sends => Mailboxes, closed => false}}}}.
queue_state(Owner) -> #{owner => Owner, closed => false, items => queue:new(), waiting => none}.

handle_call(Request, From = {Caller, _}, State) ->
    try request(Request, Caller, From, State) catch
        throw:{invalid, Reason} -> {reply, {error, Reason}, State}
    end.
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Monitor, process, _, _}, State = #{owner := Monitor}) -> {stop, normal, State};
handle_info({'DOWN', Monitor, process, _, _}, State = #{monitors := Monitors}) ->
    case maps:find(Monitor, Monitors) of
        {ok, Identity} -> {noreply, close_process(Identity, State)};
        error -> {noreply, State}
    end;
handle_info({receive_timeout, Destination, Ref}, State) ->
    Q = get_queue(Destination, State),
    case maps:get(waiting, Q) of
        {From, Ref, _} ->
            gen_server:reply(From, {error, {receive_timeout, Destination}}),
            {noreply, put_queue(Destination, Q#{waiting := none}, State)};
        _ -> {noreply, State}
    end;
handle_info(_, State) -> {noreply, State}.

request({fork, Identity, Children}, Caller, _, State) ->
    _ = owned_process(Identity, Caller, State),
    %% Reserve every child's obligations before any worker can run. A child
    %% killed before enter/2 still belongs to its parent and will be closed.
    Updated = lists:foldl(fun(Child, S) -> reserve(Identity, Child, S) end, State, Children),
    {reply, ok, Updated};
request({enter, Identity}, Caller, _, State = #{processes := Processes, monitors := Monitors}) ->
    P = get_process(Identity, State),
    require(not maps:get(closed, P) andalso maps:get(pid, P) =:= none, {cannot_enter, Identity}),
    Monitor = monitor(process, Caller),
    {reply, ok, State#{processes := Processes#{Identity := P#{pid := Caller, monitor := Monitor}},
        monitors := Monitors#{Monitor => Identity}}};
request({leave, Identity}, Caller, _, State) ->
    P = get_process(Identity, State),
    require(maps:get(closed, P) orelse maps:get(pid, P) =:= Caller, {not_process_owner, Identity}),
    {reply, ok, close_process(Identity, State)};
request({abandon, Identity, End = {'end', _, _}}, Caller, _, State) ->
    _ = owned_process(Identity, Caller, State), _ = owned_queue(Identity, End, State),
    {reply, ok, close_queue(End, State)};
request({send, Identity, Destination, Value, Clock}, Caller, _, State) ->
    _ = owned_process(Identity, Caller, State),
    case delegated(Value) of
        none -> ok;
        End ->
            _ = owned_queue(Identity, End, State),
            require(End =/= Destination, {self_delegation, End})
    end,
    {To, S1} = sending(Identity, Destination, State),
    S2 = case delegated(Value) of
        none -> S1;
        Moved -> change_owner(Moved, {queued, To}, S1)
    end,
    Q = get_queue(To, S2),
    Updated = case maps:get(closed, Q) of
        true -> discard(Value, S2);
        false -> wake(To, put_queue(To, Q#{items := queue:in({Value, Clock}, maps:get(items, Q))}, S2))
    end,
    {reply, ok, Updated};
request({'receive', Identity, Destination, Timeout}, Caller, From, State) ->
    _ = owned_process(Identity, Caller, State),
    Q = owned_queue(Identity, Destination, State),
    require(maps:get(waiting, Q) =:= none, {already_receiving, Destination}),
    require(is_integer(Timeout) andalso Timeout >= 0 andalso Timeout =< 16#ffffffff, invalid_timeout),
    Ref = make_ref(), Timer = erlang:send_after(Timeout, self(), {receive_timeout, Destination, Ref}),
    {noreply, wake(Destination, put_queue(Destination, Q#{waiting := {From, Ref, Timer}}, State))}.

reserve(Parent, #{id := Identity, ends := Ends, sends := Sends, receives := Receives}, State) ->
    Processes = maps:get(processes, State),
    require(not maps:is_key(Identity, Processes), {duplicate_process, Identity}),
    P = get_process(Parent, State), Quotas = maps:get(sends, P),
    Remaining = maps:fold(fun(Name, Count, Acc) ->
        Available = maps:get(Name, Acc, 0),
        require(is_integer(Count) andalso Count >= 0 andalso Count =< Available, {send_quota, Name}),
        Acc#{Name => Available - Count}
    end, Quotas, Sends),
    S1 = lists:foldl(fun(Destination, S) ->
        Q = owned_queue(Parent, Destination, S),
        require(maps:get(waiting, Q) =:= none, {already_receiving, Destination}),
        change_owner(Destination, Identity, S)
    end, State, Ends ++ [{mailbox, Name} || Name <- Receives]),
    Child = #{pid => none, monitor => none, parent => Parent, sends => Sends, closed => false},
    S1#{processes := Processes#{Parent := P#{sends := Remaining}, Identity => Child}}.

sending(Identity, End = {'end', Name, Side}, State) ->
    _ = owned_queue(Identity, End, State), {{'end', Name, 1 - Side}, State};
sending(Identity, Box = {mailbox, Name}, State = #{processes := Processes}) ->
    P = get_process(Identity, State), Quotas = maps:get(sends, P), Count = maps:get(Name, Quotas, 0),
    require(Count > 0, {send_quota, Name}),
    Q = get_queue(Box, State),
    S = State#{processes := Processes#{Identity := P#{sends := Quotas#{Name => Count - 1}}}},
    {Box, put_queue(Box, Q#{outstanding := maps:get(outstanding, Q) - 1}, S)}.

get_process(Identity, #{processes := Processes}) ->
    case maps:find(Identity, Processes) of
        {ok, P} -> P;
        error -> throw({invalid, {unknown_process, Identity}})
    end.
owned_process(Identity, Caller, State) ->
    P = get_process(Identity, State),
    require(not maps:get(closed, P) andalso maps:get(pid, P) =:= Caller, {not_process_owner, Identity}), P.
get_queue(Destination, #{queues := Queues}) ->
    case maps:find(Destination, Queues) of
        {ok, Q} -> Q;
        error -> throw({invalid, {unknown_destination, Destination}})
    end.
owned_queue(Identity, Destination, State) ->
    Q = get_queue(Destination, State),
    require(not maps:get(closed, Q) andalso maps:get(owner, Q) =:= Identity,
        {not_endpoint_owner, Destination}), Q.
put_queue(Destination, Q, State = #{queues := Queues}) -> State#{queues := Queues#{Destination := Q}}.
change_owner(Destination, Owner, State) ->
    Q = get_queue(Destination, State), put_queue(Destination, Q#{owner := Owner}, State).
require(true, _) -> ok;
require(false, Reason) -> throw({invalid, Reason}).
delegated({lawspec_scenario_end, Name, Side}) -> {'end', Name, Side};
delegated(_) -> none.
discard(Value, State) ->
    case delegated(Value) of none -> State; End -> close_queue(End, State) end.

%% Drain accepted values before reporting that a sender has gone. A moved
%% end is owned by the queue until its recipient actually receives it.
wake(Destination, State) ->
    Q = get_queue(Destination, State),
    case maps:get(waiting, Q) of
        none -> State;
        Waiting ->
            case queue:out(maps:get(items, Q)) of
                {{value, {Value, Clock}}, Remaining} ->
                    S1 = put_queue(Destination, Q#{items := Remaining, waiting := none}, State),
                    S2 = case delegated(Value) of
                        none -> S1;
                        End -> change_owner(End, maps:get(owner, Q), S1)
                    end,
                    reply(Waiting, {value, Value, Clock}), S2;
                {empty, _} ->
                    Gone = case Destination of
                        {mailbox, _} -> maps:get(outstanding, Q) =:= 0;
                        {'end', Name, Side} -> maps:get(closed, get_queue({'end', Name, 1 - Side}, State))
                    end,
                    case Gone of
                        true -> reply(Waiting, gone), put_queue(Destination, Q#{waiting := none}, State);
                        false -> State
                    end
            end
    end.
reply(none, _) -> ok;
reply({From, _, Timer}, Value) -> erlang:cancel_timer(Timer), gen_server:reply(From, Value).

close_queue(Destination, State) ->
    Q = get_queue(Destination, State),
    case maps:get(closed, Q) of
        true -> State;
        false ->
            reply(maps:get(waiting, Q), gone),
            S1 = put_queue(Destination, Q#{closed := true, items := queue:new(), waiting := none}, State),
            %% Mark closed before following delegated ends: even cyclic
            %% queues cannot recurse forever or call another server.
            S2 = lists:foldl(fun({Value, _}, S) -> discard(Value, S) end, S1, queue:to_list(maps:get(items, Q))),
            case Destination of
                {'end', Name, Side} -> wake({'end', Name, 1 - Side}, S2);
                {mailbox, _} -> S2
            end
    end.
close_process(Identity, State) ->
    P = get_process(Identity, State),
    case maps:get(closed, P) of
        true -> State;
        false ->
            Monitor = maps:get(monitor, P),
            case Monitor of none -> ok; _ -> demonitor(Monitor, [flush]) end,
            Processes = maps:get(processes, State),
            S1 = State#{processes := Processes#{Identity := P#{closed := true, sends := #{}}},
                monitors := maps:remove(Monitor, maps:get(monitors, State))},
            Children = [I || {I, #{parent := Parent}} <- maps:to_list(Processes), Parent =:= Identity],
            S2 = lists:foldl(fun close_process/2, S1, Children),
            Destinations = [D || {D, #{owner := Owner}} <- maps:to_list(maps:get(queues, S2)),
                Owner =:= Identity orelse Identity =:= root],
            S3 = lists:foldl(fun close_queue/2, S2, Destinations),
            maps:fold(fun(Name, Count, S) ->
                Box = {mailbox, Name}, Q = get_queue(Box, S),
                wake(Box, put_queue(Box, Q#{outstanding := maps:get(outstanding, Q) - Count}, S))
            end, S3, maps:get(sends, P))
    end.
