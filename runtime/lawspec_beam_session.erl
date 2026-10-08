%% @doc Affine native session ends. A channel owns both queues and advances
%% each end exactly once per step. Delegated ends belong to the destination
%% queue until its receiver claims them, including when a sender dies.
%% ref:DEC-sessions-by-construction ref:DEC-async-native-tasks
-module(lawspec_beam_session).
-behaviour(gen_server).
-export([open/1, with_pair/2, with_owned/2, claim/1, send/2, receive_value/1,
    send_end/2, receive_end/1, abandon/1, specification/1, transfer_to_task/2]).
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
        graph => Graph, graph_monitor => monitor(process, Graph)}}.
handle_call(open, _, State) ->
    finish({ok, {handle(0, State), handle(1, State)}}, State);
handle_call(barrier, _, State) -> finish({ok, ok}, State);
handle_call({Operation, End}, From, State) ->
    try local(Operation, End, From, State) catch
        throw:{invalid, Reason} -> {reply, {error, Reason}, State}
    end;
handle_call(_, _, State) -> {reply, {error, invalid_operation}, State}.
handle_cast({discard, End, Owner}, State) ->
    finish(discard_owned(End, Owner, State));
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Ref, process, _, _}, State = #{graph_monitor := Ref}) -> {stop, normal, State};
handle_info({'DOWN', Ref, process, _, _}, State = #{resource := {Ref, Generations}}) ->
    finish(maps:fold(fun(Side, Generation, Acc) ->
        discard_owned({lawspec_session, self(), Side, Generation, 0}, any, Acc)
    end, State#{resource := none}, Generations));
handle_info({'DOWN', Ref, process, _, Reason}, State = #{jobs := Jobs}) ->
    case maps:take(Ref, Jobs) of
        {#{side := Side}, Rest} ->
            Result = case Reason of {delegated, Outcome} -> Outcome; _ -> {error, {transfer_failed, Reason}} end,
            finish(delegated(Side, Result, State#{jobs := Rest}));
        error -> finish(owner_down(Ref, Reason, State))
    end;
handle_info(_, State) -> {noreply, State}.
terminate(_, State) ->
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
    require(element(1, part(Side, E, send, State)) =:= value, expected_delegation),
    Next = enqueue(1 - Side, {value, Value}, advance(Side, E, Caller, State)),
    finish({ok, handle(Side, Next)}, wake(1 - Side, Next));
local({send_end, Other}, End, From = {Caller, _}, State) ->
    {Side, E} = get_end(End, State),
    Part = part(Side, E, send, State),
    Expected = case Part of {session, Id} -> Id; _ -> throw({invalid, expected_value}) end,
    OtherPid = case Other of {lawspec_session, P, 0, _, 0} -> P; _ -> throw({invalid, not_an_unused_first_end}) end,
    require(OtherPid =/= self(), cyclic_delegation),
    S1 = advance(Side, E, Caller, State),
    Scope = case maps:get(scope, S1) of none -> lawspec_beam_tasks:open(); Given -> Given end,
    Parent = self(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        receive go -> ok end,
        Result = try {ok, request(Other, {transfer, Expected, Parent})}
            catch error:{lawspec, {session, Reason}} -> {error, Reason} end,
        exit({delegated, Result})
    end),
    ok = lawspec_beam_tasks:adopt(Scope, Worker), Worker ! go,
    Jobs = maps:get(jobs, S1),
    E1 = maps:get(Side, maps:get(ends, S1)),
    {noreply, put_end(Side, E1#{sending := From}, S1#{scope := Scope, jobs := Jobs#{Monitor => #{side => Side}}})};
local(Operation, End, From = {Caller, _}, State) when Operation =:= receive_value; Operation =:= receive_end ->
    {Side, E} = get_end(End, State),
    Part = part(Side, E, 'receive', State),
    require((Operation =:= receive_value andalso element(1, Part) =:= value) orelse
        (Operation =:= receive_end andalso element(1, Part) =:= session), wrong_receive_kind),
    Next = advance(Side, E, Caller, State),
    E1 = maps:get(Side, maps:get(ends, Next)),
    finish(wake(Side, put_end(Side, E1#{reader := From}, Next)));
local({received, Ticket}, End, {Caller, _}, State) ->
    {Side, E} = get_end(End, State),
    require(case maps:get(delivery, E) of {Ticket, Caller, _} -> true; _ -> false end, invalid_receipt),
    finish({ok, ok}, put_end(Side, E#{delivery := none}, State)).

delegated(Side, Result, State = #{ends := Ends}) ->
    E = maps:get(Side, Ends), From = maps:get(sending, E),
    S1 = put_end(Side, E#{sending := none}, State),
    case Result of
        {ok, Other} ->
            S2 = enqueue(1 - Side, {session, Other}, S1),
            gen_server:reply(From, {ok, handle(Side, S2)}), wake(1 - Side, S2);
        {error, Reason} ->
            gen_server:reply(From, {error, Reason}), close_end(Side, S1)
    end.
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
    Next = put_end(Side, E#{closed := true, owner := none, reader := none,
        delivery := none, queue := queue:new()}, State),
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
