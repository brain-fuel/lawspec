%% @doc Affine native session ends. A channel owns both queues and advances
%% each end exactly once per step. Delegated ends belong to the destination
%% queue until its receiver claims them, including when a sender dies.
%% ref:DEC-sessions-by-construction ref:DEC-async-native-tasks
-module(lawspec_beam_session).
-behaviour(gen_server).
-export([open/1, with_pair/2, with_owned/2, claim/1, send/2, receive_value/1,
    send_end/2, receive_end/1, abandon/1, specification/1, transfer_to_task/2,
    listen/3, dial/3, address/1, network_start/6, network_endpoint/1, network_offer/2, transfer_to_relay/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export_type([session/0]).

-opaque session() :: {lawspec_session, pid(), 0 | 1, reference(), non_neg_integer()}.

open(Spec) -> open(Spec, none).
open(Spec, Owner) ->
    {ok, Channel} = gen_server:start(?MODULE, {Spec, Owner}, []),
    {First, Second} = Pair = call(Channel, open),
    case {get({?MODULE, owned}), maps:get(maps:get(id, Spec), maps:get(protocols, Spec))} of
        {undefined, _} -> ok; {_, []} -> ok; _ -> claim(First), claim(Second)
    end,
    Pair.
with_pair(Spec, Body) ->
    {First, Second} = open(Spec, self()),
    try Body(First, Second) after discard(First, any), discard(Second, any), barrier(First) end.

%% The monitor also covers an untrappable kill. Tracking dynamically received
%% ends makes a caught exception give up the ends acquired during this body.
with_owned(Ends, Body) ->
    Key = {?MODULE, owned}, Previous = get(Key), put(Key, #{}),
    try
        lists:foreach(fun claim/1, Ends), Body()
    catch Class:Reason:Stack ->
        maps:foreach(fun(_, End) -> discard(End, self()) end, get(Key)),
        erlang:raise(Class, Reason, Stack)
    after
        Acquired = get(Key),
        case Previous of undefined -> erase(Key); _ -> put(Key, maps:merge(Previous, Acquired)) end
    end.
track(End = {lawspec_session, Pid, Side, Generation, _}) ->
    case get({?MODULE, owned}) of
        undefined -> ok;
        Owned -> put({?MODULE, owned}, Owned#{{Pid, Side, Generation} => End})
    end,
    End.
claim(End) -> _ = request(End, claim), track(End), ok.
send(End, Value) -> track(request(End, {send, Value})).
receive_value(End) ->
    {Value, Next} = request(End, receive_value), {Value, track(Next)}.
send_end(End, Other) -> track(request(End, {send_end, Other})).
receive_end(End) ->
    {Other, Next, Ticket} = request(End, receive_end),
    try claim(Other) catch Class:Reason:Stack ->
        discard(Next, self()), erlang:raise(Class, Reason, Stack)
    end,
    %% Claim precedes acknowledgement: a completed parent channel cannot
    %% disappear while the delegated end still belongs to its queue.
    try _ = request(Next, {received, Ticket}) catch error:{lawspec, {session, closed}} -> ok end,
    {Other, track(Next)}.
abandon(End) -> request(End, abandon).
specification(End) -> request(End, specification).
transfer_to_task(End, Worker) when is_pid(Worker) -> request(End, {transfer_to_task, Worker}).
listen(Node, Name, Spec) -> network_start(Spec, Node, Name, 0, none, none).
dial(Node, Address, Spec) ->
    network_start(Spec, Node, lawspec_beam_session_network:fresh_name(), 1, Address, none).
address(End) -> request(End, address).
network_endpoint(End) -> request(End, network_endpoint).
network_offer(End, Expected) -> request(End, {network_offer, Expected}).
transfer_to_relay(End, Expected, Worker) -> request(End, {transfer_to_relay, Expected, Worker}).
network_start(Spec, Node, Name, Side, Connection, Custodian) ->
    ok = lawspec_beam_session_network:validate(Spec),
    case gen_server:start(?MODULE, {network, Spec, Node, Name, Side, Custodian}, []) of
        {ok, Channel} ->
            End = element(Side + 1, call(Channel, open)),
            try
                case Connection of none -> ok; _ -> lawspec_beam_endpoint:connect(network_endpoint(End), Connection) end,
                case {Custodian, get({?MODULE, owned})} of
                    {none, Owned} when Owned =/= undefined -> claim(End); _ -> ok
                end,
                End
            catch Class:Reason:Stack ->
                try lawspec_beam_endpoint:stop(network_endpoint(End)) catch _:_ -> ok end,
                discard(End, any), erlang:raise(Class, Reason, Stack)
            end;
        {error, Reason} -> fail({network_start, Reason})
    end.
request(End = {lawspec_session, Pid, _, _, _}, Operation) -> call(Pid, {Operation, End});
request(_, _) -> fail(invalid_end).
call(Pid, Request) ->
    Result = try gen_server:call(Pid, Request, infinity)
        catch exit:{_, {gen_server, call, [Pid, _, infinity]}} -> {error, closed} end,
    case Result of {ok, Value} -> Value; {error, Reason} -> fail(Reason) end.
fail(Reason) -> error({lawspec, {session, Reason}}).
discard({lawspec_session, Pid, _, _, _} = End, Owner) -> gen_server:cast(Pid, {discard, End, Owner}).
barrier({lawspec_session, Pid, _, _, _}) ->
    try _ = call(Pid, barrier) catch error:{lawspec, {session, closed}} -> ok end.

init({network, Spec, Node, Name, Side, Custodian}) ->
    {ok, State} = init({Spec, none}),
    try
        ok = lawspec_beam_node:adopt_service(Node, self()),
        Deadline = maps:get(deadline, Spec, 5000),
        Ends = maps:get(ends, State), Peer = maps:get(1 - Side, Ends),
        Own = case Custodian of
            none -> maps:get(Side, Ends);
            _ -> ok = lawspec_beam_session_ownership:move(maps:get(graph, State), self(), Custodian),
                own(maps:get(Side, Ends), Custodian, custody)
        end,
        {ok, Endpoint} = lawspec_beam_endpoint:start(Node, Name, #{deadline => Deadline, owner => self()}),
        Net = #{node => Node, endpoint => Endpoint, side => Side, deadline => Deadline,
            node_monitor => monitor(process, Node), endpoint_monitor => monitor(process, Endpoint),
            ticket => none, detached => false},
        {ok, State#{network := Net, ends := Ends#{Side := Own,
            (1 - Side) := Peer#{step := length(maps:get(steps, State))}}}}
    catch Class:Reason ->
        lawspec_beam_session_ownership:unregister(maps:get(graph, State), self()),
        {stop, {Class, Reason}}
    end;
init({Spec = #{id := Id, protocols := Protocols}, Owner}) ->
    Steps = maps:get(Id, Protocols),
    true = is_list(Steps),
    Ends = maps:from_list([{Side, #{generation => make_ref(), step => 0, owner => none,
        closed => false, queue => queue:new(), reader => none, sending => none, delivery => none}}
        || Side <- [0, 1]]),
    Resource = case Owner of none -> none; _ -> {monitor(process, Owner),
        maps:map(fun(_, E) -> maps:get(generation, E) end, Ends)} end,
    Graph = lawspec_beam_session_ownership:register(self()),
    {ok, #{spec => Spec, steps => Steps, ends => Ends, resource => Resource, scope => none, jobs => #{},
        graph => Graph, graph_monitor => monitor(process, Graph), network => none}}.
handle_call(open, _, State) ->
    finish({ok, {handle(0, State), handle(1, State)}}, State);
handle_call(barrier, _, State) -> finish({ok, ok}, State);
handle_call({Operation, End}, From, State) ->
    try local(Operation, End, From, State) catch
        throw:{invalid, Reason} -> {reply, {error, Reason}, State};
        error:{lawspec, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call(_, _, State) -> {reply, {error, invalid_operation}, State}.
handle_cast({discard, End, Owner}, State) ->
    finish(discard_owned(End, Owner, State));
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Ref, process, _, _}, State = #{graph_monitor := Ref}) -> {stop, normal, State};
handle_info({'DOWN', Ref, process, _, _}, State = #{network := #{node_monitor := N, endpoint_monitor := E}})
        when Ref =:= N; Ref =:= E -> {stop, normal, State};
handle_info({lawspec_channel, Endpoint, Ticket, Result}, State = #{network := #{endpoint := Endpoint, ticket := {Ticket, Part}} = Net}) ->
    finish(network_received(Part, Result, State#{network := Net#{ticket := none}}));
handle_info({'DOWN', Ref, process, _, _}, State = #{resource := {Ref, Generations}}) ->
    finish(maps:fold(fun(Side, Generation, Acc) ->
        discard_owned({lawspec_session, self(), Side, Generation, 0}, any, Acc)
    end, State#{resource := none}, Generations));
handle_info({'DOWN', Ref, process, _, Reason}, State = #{jobs := Jobs}) ->
    case maps:take(Ref, Jobs) of
        {#{side := Side, kind := Kind}, Rest} ->
            Result = case Reason of {delegated, Outcome} -> Outcome; _ -> {error, {transfer_failed, Reason}} end,
            finish(job_result(Kind, Side, Result, State#{jobs := Rest}));
        error -> finish(owner_down(Ref, Reason, State))
    end;
handle_info(_, State) -> {noreply, State}.
terminate(_, State) ->
    network_close(maps:get(network, State)),
    maps:foreach(fun(_, E) ->
        close_owner(E), reply_waiters(E, {error, closed}), discard_contents(E)
    end, maps:get(ends, State)),
    case maps:get(scope, State) of none -> ok; Scope -> lawspec_beam_tasks:close(Scope) end,
    lawspec_beam_session_ownership:unregister(maps:get(graph, State), self()).

handle(Side, #{ends := Ends}) ->
    #{generation := Generation, step := Step} = maps:get(Side, Ends),
    {lawspec_session, self(), Side, Generation, Step}.
get_end({lawspec_session, Pid, Side, Generation, Step}, State) when Pid =:= self(), (Side =:= 0 orelse Side =:= 1) ->
    E = maps:get(Side, maps:get(ends, State)),
    require(maps:get(generation, E) =:= Generation andalso maps:get(step, E) =:= Step, spent_end),
    require(not maps:get(closed, E), abandoned_end), {Side, E};
get_end(_, _) -> throw({invalid, invalid_end}).
require(true, _) -> ok;
require(false, Reason) -> throw({invalid, Reason}).
put_end(Side, End, State = #{ends := Ends}) -> State#{ends := Ends#{Side := End}}.
part(Side, E, Direction, #{steps := Steps}) ->
    Step = maps:get(step, E),
    require(Step < length(Steps), protocol_complete),
    {FirstDirection, Part} = lists:nth(Step + 1, Steps),
    Actual = case {Side, FirstDirection} of {0, D} -> D; {1, send} -> 'receive'; {1, 'receive'} -> send end,
    require(Actual =:= Direction, wrong_step), Part.
own(E, Caller, Mode) ->
    close_owner(E), E#{owner := {Caller, monitor(process, Caller), Mode}}.
close_owner(#{owner := none}) -> ok;
close_owner(#{owner := {_, Monitor, _}}) -> demonitor(Monitor, [flush]), ok.
advance(Side, E, Caller, State) ->
    require(maps:get(sending, E) =:= none andalso maps:get(delivery, E) =:= none, operation_in_progress),
    release_custody(Side, E, State),
    put_end(Side, (own(E, Caller, process))#{step := maps:get(step, E) + 1}, State).
release_custody(0, #{owner := {_, _, custody}}, #{graph := Graph}) ->
    lawspec_beam_session_ownership:release(Graph, self());
release_custody(_, _, _) -> ok.

local(specification, End, _, State) ->
    _ = get_end(End, State), {reply, {ok, maps:get(spec, State)}, State};
local(network_endpoint, End, _, State = #{network := Net}) ->
    _ = get_end(End, State), require(Net =/= none, local_end),
    {reply, {ok, maps:get(endpoint, Net)}, State};
local(address, End, From, State = #{network := Net}) ->
    _ = local(network_endpoint, End, From, State),
    {reply, {ok, lawspec_beam_endpoint:address(maps:get(endpoint, Net))}, State};
local(claim, End, {Caller, _}, State) ->
    {Side, E} = get_end(End, State),
    release_custody(Side, E, State),
    {reply, {ok, ok}, put_end(Side, own(E, Caller, process), State)};
local(abandon, End, _, State) ->
    {Side, _} = get_end(End, State), finish({ok, ok}, close_end(Side, State));
local({transfer_to_task, Worker}, End, _, State) ->
    {Side, E} = get_end(End, State),
    require(maps:get(reader, E) =:= none andalso maps:get(sending, E) =:= none andalso maps:get(delivery, E) =:= none,
        operation_in_progress),
    release_custody(Side, E, State),
    Next = put_end(Side, (own(E, Worker, process))#{generation := make_ref()}, State),
    {reply, {ok, handle(Side, Next)}, Next};
local({transfer_to_relay, Expected, Worker}, End, From, State) ->
    unused_first(End, Expected, State), local({transfer_to_task, Worker}, End, From, State);
local({network_offer, Expected}, End, _, State = #{network := Net}) ->
    unused_first(End, Expected, State),
    case Net of
        none -> {reply, {ok, {local, maps:get(spec, State)}}, State};
        _ ->
            Address = lawspec_beam_endpoint:offer(maps:get(endpoint, Net)),
            {Side, E} = get_end(End, State), release_custody(Side, E, State), close_owner(E),
            Next = put_end(Side, E#{generation := make_ref(), closed := true, owner := none},
                State#{network := Net#{detached := true}}),
            finish({ok, {address, Address}}, Next)
    end;
local({transfer, Expected, Custodian}, End, _, State = #{spec := #{id := Id}}) ->
    {Side, E} = get_end(End, State),
    require(Side =:= 0 andalso maps:get(step, E) =:= 0, not_an_unused_first_end),
    require(Id =:= Expected, different_protocol),
    case lawspec_beam_session_ownership:move(maps:get(graph, State), self(), Custodian) of
        ok -> ok; {error, Reason} -> throw({invalid, Reason}) end,
    Next = put_end(Side, (own(E, Custodian, custody))#{generation := make_ref()}, State),
    {reply, {ok, handle(Side, Next)}, Next};
local({send, Value}, End, {Caller, _}, State) ->
    {Side, E} = get_end(End, State),
    Part = part(Side, E, send, State),
    require(element(1, Part) =:= value, expected_delegation),
    %% Validate wire bytes before advancing the affine handle.
    network_send(Part, Value, State),
    S1 = advance(Side, E, Caller, State),
    Next = case maps:get(network, State) of none -> enqueue(1 - Side, {value, Value}, S1); _ -> S1 end,
    finish({ok, handle(Side, Next)}, wake(1 - Side, Next));
local({send_end, Other}, End, From = {Caller, _}, State) ->
    {Side, E} = get_end(End, State),
    Part = part(Side, E, send, State),
    Expected = case Part of {session, Id} -> Id; _ -> throw({invalid, expected_value}) end,
    OtherPid = case Other of {lawspec_session, P, 0, _, 0} -> P; _ -> throw({invalid, not_an_unused_first_end}) end,
    require(OtherPid =/= self(), cyclic_delegation),
    S1 = advance(Side, E, Caller, State),
    Parent = self(),
    Work = case maps:get(network, State) of
        none -> fun() -> request(Other, {transfer, Expected, Parent}) end;
        #{node := Node} -> fun() -> lawspec_beam_session_network:offer(Node, Other, Expected) end
    end,
    E1 = maps:get(Side, maps:get(ends, S1)),
    {noreply, start_job(Side, send, Work, put_end(Side, E1#{sending := From}, S1))};
local(Operation, End, From = {Caller, _}, State) when Operation =:= receive_value; Operation =:= receive_end ->
    {Side, E} = get_end(End, State),
    Part = part(Side, E, 'receive', State),
    require((Operation =:= receive_value andalso element(1, Part) =:= value) orelse
        (Operation =:= receive_end andalso element(1, Part) =:= session), wrong_receive_kind),
    Next = advance(Side, E, Caller, State),
    E1 = maps:get(Side, maps:get(ends, Next)),
    Waiting = put_end(Side, E1#{reader := From}, Next),
    case maps:get(network, State) of
        none -> finish(wake(Side, Waiting));
        #{endpoint := Endpoint, deadline := Deadline} = Net ->
            Ticket = lawspec_beam_endpoint:receive_async(Endpoint, Deadline),
            {noreply, Waiting#{network := Net#{ticket := {Ticket, Part}}}}
    end;
local({received, Ticket}, End, {Caller, _}, State) ->
    {Side, E} = get_end(End, State),
    require(case maps:get(delivery, E) of {Ticket, Caller, _} -> true; _ -> false end, invalid_receipt),
    finish({ok, ok}, put_end(Side, E#{delivery := none}, State)).

unused_first(End, Expected, State = #{spec := #{id := Id}}) ->
    {Side, E} = get_end(End, State),
    require(Side =:= 0 andalso maps:get(step, E) =:= 0, not_an_unused_first_end),
    require(Id =:= Expected, different_protocol).
start_job(Side, Kind, Work, State = #{jobs := Jobs}) ->
    Scope = case maps:get(scope, State) of none -> lawspec_beam_tasks:open(); Given -> Given end,
    Parent = self(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        Ready = monitor(process, Parent),
        receive go -> demonitor(Ready, [flush]); {'DOWN', Ready, process, Parent, _} -> exit(normal) end,
        Result = try {ok, Work()} catch
            error:{lawspec, {session, Reason}} -> {error, Reason};
            Class:Reason -> {error, {transfer_failed, Class, Reason}}
        end,
        exit({delegated, Result})
    end),
    ok = lawspec_beam_tasks:adopt(Scope, Worker), Worker ! go,
    State#{scope := Scope, jobs := Jobs#{Monitor => #{side => Side, kind => Kind}}}.
job_result('receive', Side, {ok, Other}, State) -> wake(Side, enqueue(Side, {session, Other}, State));
job_result('receive', Side, {error, Reason}, State) -> network_failed(Side, Reason, State);
job_result(send, Side, Result, State = #{ends := Ends}) ->
    E = maps:get(Side, Ends), From = maps:get(sending, E),
    S1 = put_end(Side, E#{sending := none}, State),
    case Result of
        {ok, Other} ->
            try
                S2 = case maps:get(network, S1) of
                    none -> enqueue(1 - Side, {session, Other}, S1);
                    _ -> network_send({session, none}, Other, S1), S1
                end,
                gen_server:reply(From, {ok, handle(Side, S2)}), wake(1 - Side, S2)
            catch Class:Reason ->
                gen_server:reply(From, {error, {transfer_failed, Class, Reason}}), close_end(Side, S1)
            end;
        {error, Reason} ->
            gen_server:reply(From, {error, Reason}), close_end(Side, S1)
    end.
network_send(_, _, #{network := none}) -> ok;
network_send(Part, Value, #{network := #{endpoint := Endpoint}}) ->
    lawspec_beam_endpoint:send(Endpoint, lawspec_beam_session_network:encode(Part, Value)).
network_received(_, {error, Reason}, State = #{network := #{side := Side}}) -> network_failed(Side, Reason, State);
network_received(Part, {value, Bytes}, State = #{network := #{side := Side, node := Node}}) ->
    try lawspec_beam_session_network:decode(Part, Bytes) of
        Value -> case Part of
            {value, _} -> wake(Side, enqueue(Side, {value, Value}, State));
            {session, Id} ->
                Spec = (maps:get(spec, State))#{id := Id}, Parent = self(),
                start_job(Side, 'receive', fun() -> lawspec_beam_session_network:take(Node, Value, Spec, Parent) end, State)
        end
    catch Class:Reason -> network_failed(Side, {invalid_payload, Class, Reason}, State) end.
network_failed(Side, Reason, State = #{ends := Ends}) ->
    E = maps:get(Side, Ends), reply_reader(E, {error, {peer_failed, Reason}}),
    close_end(Side, put_end(Side, E#{reader := none}, State)).
network_close(none) -> ok;
network_close(#{detached := true}) -> ok;
network_close(#{endpoint := Endpoint}) ->
    try lawspec_beam_endpoint:abandon(Endpoint) catch _:_ -> ok end.
enqueue(Side, Item, State = #{ends := Ends}) ->
    E = maps:get(Side, Ends),
    case maps:get(closed, E) of
        true -> discard_item(Item), State;
        false -> put_end(Side, E#{queue := queue:in(Item, maps:get(queue, E))}, State)
    end.
wake(Side, State = #{ends := Ends}) ->
    E = maps:get(Side, Ends), Peer = maps:get(1 - Side, Ends),
    case maps:get(reader, E) of
        none -> State;
        From = {Caller, _} ->
            case queue:out(maps:get(queue, E)) of
                {{value, {Kind, Value}}, Rest} ->
                    Next = handle(Side, State),
                    {Reply, Delivery} = case Kind of
                        value -> {{Value, Next}, none};
                        session -> Ticket = make_ref(), {{Value, Next, Ticket}, {Ticket, Caller, Value}}
                    end,
                    gen_server:reply(From, {ok, Reply}),
                    put_end(Side, E#{queue := Rest, reader := none, delivery := Delivery}, State);
                {empty, _} ->
                    case maps:get(closed, Peer) andalso maps:get(sending, Peer) =:= none of
                        true -> gen_server:reply(From, {error, peer_failed}),
                            close_end(Side, put_end(Side, E#{reader := none}, State));
                        false -> State
                    end
            end
    end.
close_end(Side, State = #{ends := Ends}) ->
    E = maps:get(Side, Ends),
    release_custody(Side, E, State),
    close_owner(E), reply_reader(E, {error, abandoned_end}), discard_contents(E),
    Next0 = put_end(Side, E#{closed := true, owner := none, reader := none,
        delivery := none, queue := queue:new()}, State),
    Next = case maps:get(network, State) of
        #{side := Side} = Net ->
            network_close(Net),
            Peer = maps:get(1 - Side, maps:get(ends, Next0)),
            put_end(1 - Side, Peer#{closed := true}, Next0);
        _ -> Next0
    end,
    wake(1 - Side, Next).
reply_reader(#{reader := none}, _) -> ok;
reply_reader(#{reader := From}, Result) -> gen_server:reply(From, Result).
reply_waiters(E, Result) ->
    reply_reader(E, Result),
    case maps:get(sending, E) of none -> ok; From -> gen_server:reply(From, Result) end.
discard_contents(#{queue := Queue, delivery := Delivery}) ->
    lists:foreach(fun discard_item/1, queue:to_list(Queue)),
    case Delivery of none -> ok; {_, _, End} -> discard(End, self()) end.
discard_item({session, End}) -> discard(End, self());
discard_item({value, _}) -> ok.
discard_owned({lawspec_session, Pid, Side, Generation, _}, Owner, State = #{ends := Ends}) when Pid =:= self() ->
    E = maps:get(Side, Ends),
    Matches = Owner =:= any orelse case maps:get(owner, E) of {Owner, _, _} -> true; _ -> false end,
    case maps:get(generation, E) =:= Generation andalso Matches of true -> close_end(Side, State); false -> State end.
owner_down(Ref, Reason, State = #{ends := Ends}) ->
    lists:foldl(fun(Side, Acc) ->
        E = maps:get(Side, maps:get(ends, Acc)),
        case maps:get(owner, E) of
            {_, Ref, Mode} ->
                case Mode =:= process andalso successful_exit(Reason) andalso maps:get(reader, E) =:= none
                    andalso maps:get(delivery, E) =:= none andalso maps:get(sending, E) =:= none of
                    true -> put_end(Side, E#{owner := none}, Acc);
                    false -> close_end(Side, Acc)
                end;
            _ -> Acc
        end
    end, State, maps:keys(Ends)).
successful_exit(normal) -> true;
successful_exit({lawspec_result, {ok, _}}) -> true;
successful_exit({lawspec_session_result, {ok, _}}) -> true;
successful_exit(_) -> false.
finished(#{ends := Ends, steps := Steps, jobs := Jobs}) ->
    map_size(Jobs) =:= 0 andalso lists:all(fun(E) ->
        (maps:get(closed, E) orelse maps:get(step, E) =:= length(Steps)) andalso
        maps:get(reader, E) =:= none andalso maps:get(delivery, E) =:= none andalso queue:is_empty(maps:get(queue, E))
    end, maps:values(Ends)).
settle(State = #{ends := Ends, jobs := Jobs, scope := Scope}) ->
    case map_size(Jobs) > 0 andalso lists:all(fun(E) -> maps:get(closed, E) end, maps:values(Ends)) of
        false -> State;
        true ->
            %% Nothing can receive a pending transfer now. Join its helper
            %% even if the other channel is suspended or unreachable.
            lawspec_beam_tasks:close(Scope),
            maps:foreach(fun(Ref, _) -> demonitor(Ref, [flush]) end, Jobs),
            Clean = maps:map(fun(_, E) -> reply_waiters(E, {error, closed}), E#{sending := none} end, Ends),
            State#{ends := Clean, jobs := #{}, scope := none}
    end.
finish(State0) ->
    State = settle(State0), case finished(State) of true -> {stop, normal, State}; false -> {noreply, State} end.
finish(Reply, State0) ->
    State = settle(State0), case finished(State) of true -> {stop, normal, Reply, State}; false -> {reply, Reply, State} end.
