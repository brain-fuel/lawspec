%% @doc A node owns each reliable channel end, its retry timer and pending
%% readers. Abandonment is an ordered frame; it keeps retrying after the
%% application leaves. Moving an unused end transfers its protocol state.
%% ref:DEC-distribution-canonical-wire ref:DEC-sessions-by-construction
-module(lawspec_beam_endpoint).
-behaviour(gen_server).
-export([start/3, stop/1, address/1, connect/2, send/2, abandon/1,
    receive_body/2, receive_async/2, cancel/2, offer/1, take/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start(Node, Name, Options) -> gen_server:start(?MODULE, {Node, Name, Options}, []).
%% stop/1 destroys the service. Normal conversation cleanup uses abandon/1
%% so accepted sends and EOF can still be acknowledged by the peer.
stop(End) ->
    try gen_server:stop(End, normal, infinity)
    catch exit:noproc -> ok; exit:{noproc, _} -> ok end.
address(End) -> call(End, address).
connect(End, Peer) -> call(End, {connect, Peer}).
send(End, Bytes) -> call(End, {send, Bytes}).
abandon(End) -> call(End, abandon).
receive_body(End, Timeout) -> call(End, {'receive', sync, Timeout}).
%% Delivers {lawspec_channel, End, Ticket, {value, Bytes} | {error, Reason}}.
receive_async(End, Timeout) -> call(End, {'receive', async, Timeout}).
cancel(End, Ticket) -> call(End, {cancel, Ticket}).
offer(End) -> call(End, offer).
take(End, Address) -> call(End, {take, Address}).
call(End, Request) ->
    Result = try gen_server:call(End, Request, infinity)
        catch exit:{_, {gen_server, call, [End, _, infinity]}} -> {error, endpoint_closed} end,
    case Result of {ok, Value} -> Value; {error, Reason} -> error({lawspec, {channel, Reason}}) end.

init({Node, Name, Options}) ->
    Deadline = maps:get(deadline, Options, 5000),
    case is_integer(Deadline) andalso Deadline > 0 of
        false -> {stop, invalid_deadline};
        true ->
            Address = lawspec_beam_node:register_service(Node, Name),
            {ok, #{node => Node, name => Name, node_monitor => monitor(process, Node),
                protocol => lawspec_beam_channel_protocol:new(Address, Deadline * 1000),
                reader => none, taking => none, timer => none}}
    end.
handle_call(Request, From, State) ->
    try local(Request, From, State) catch
        throw:{invalid, Reason} -> {reply, {error, Reason}, State};
        error:{lawspec, Reason} -> {reply, {error, Reason}, State};
        error:{badmatch, _} -> {reply, {error, invalid_operation}, State};
        error:badarg -> {reply, {error, invalid_operation}, State}
    end.
handle_cast(_, State) -> {noreply, State}.
handle_info({lawspec_frame, Node, Frame}, State = #{node := Node, protocol := Protocol}) ->
    {noreply, update(lawspec_beam_channel_protocol:accept(Protocol, Frame, now_us()), State)};
handle_info({tick, Ref}, State = #{timer := {Ref, _}, protocol := Protocol}) ->
    {noreply, update(lawspec_beam_channel_protocol:tick(Protocol, now_us()), State#{timer := none})};
handle_info({read_timeout, Ticket}, State = #{reader := #{ticket := Ticket}}) ->
    {noreply, finish(reader, {error, receive_timeout}, State)};
handle_info({'DOWN', Monitor, process, _, _}, State = #{node_monitor := Monitor}) -> {stop, normal, State};
handle_info({'DOWN', Monitor, process, _, _}, State = #{reader := #{monitor := Monitor}}) ->
    {noreply, finish(reader, cancelled, State)};
handle_info({'DOWN', Monitor, process, _, _}, State = #{taking := #{monitor := Monitor}}) ->
    {noreply, finish(taking, cancelled, State)};
handle_info(_, State) -> {noreply, State}.
terminate(_, State) ->
    cancel_timer(maps:get(timer, State)),
    _ = finish(reader, {error, endpoint_closed}, finish(taking, {error, endpoint_closed}, State)),
    try lawspec_beam_node:unregister(maps:get(node, State), maps:get(name, State)) catch _:_ -> ok end,
    ok.

local(address, _, State) -> {reply, {ok, maps:get(address, maps:get(protocol, State))}, State};
local({connect, Peer}, _, State = #{protocol := Protocol}) ->
    require(is_binary(Peer), invalid_address), idle_take(State),
    Next = lawspec_beam_channel_protocol:connect(Protocol, Peer, now_us()),
    {reply, {ok, ok}, update(Next, State)};
local({send, Bytes}, _, State = #{protocol := Protocol}) ->
    require(is_binary(Bytes), invalid_payload), idle_take(State),
    {reply, {ok, ok}, update(lawspec_beam_channel_protocol:send(Protocol, Bytes, now_us()), State)};
local(abandon, _, State = #{protocol := Protocol}) ->
    {reply, {ok, ok}, update(lawspec_beam_channel_protocol:abandon(Protocol, now_us()), State)};
local({'receive', Mode, Timeout}, From, State) ->
    idle_take(State), require(maps:get(reader, State) =:= none, already_receiving),
    require(Timeout =:= infinity orelse (is_integer(Timeout) andalso Timeout >= 0 andalso Timeout =< 16#ffffffff), invalid_timeout),
    Waiter = waiting(Mode, From, Timeout),
    Next = wake(State#{reader := Waiter}),
    case Mode of
        sync -> {noreply, Next};
        async -> {reply, {ok, maps:get(ticket, Waiter)}, Next}
    end;
local({cancel, Ticket}, {Caller, _}, State) ->
    Next = case maps:get(reader, State) of
        #{ticket := Ticket, caller := Caller} -> finish(reader, cancelled, State);
        _ -> State
    end,
    {reply, {ok, ok}, Next};
local(offer, _, State = #{protocol := Protocol}) ->
    idle_take(State), require(maps:get(reader, State) =:= none, already_receiving),
    Token = binary:encode_hex(crypto:strong_rand_bytes(24)),
    {Address, Next} = lawspec_beam_channel_protocol:offer(Protocol, Token),
    {reply, {ok, Address}, State#{protocol := Next}};
local({take, Address}, From, State = #{protocol := Protocol}) ->
    idle_take(State), require(maps:get(reader, State) =:= none, already_receiving),
    require(maps:get(peer, Protocol) =:= none andalso maps:get(unacked, Protocol) =:= #{} andalso
        maps:get(expected, Protocol) =:= 0 andalso maps:get(taking, Protocol) =:= none, end_not_fresh),
    Next = lawspec_beam_channel_protocol:take(Protocol, Address, now_us()),
    {noreply, update(Next, State#{taking := waiting(sync, From, infinity)})}.
idle_take(State) -> require(maps:get(taking, State) =:= none, taking_in_progress).
require(true, _) -> ok;
require(false, Reason) -> throw({invalid, Reason}).
now_us() -> erlang:monotonic_time(microsecond).

waiting(Mode, From = {Caller, _}, Timeout) ->
    Ticket = make_ref(),
    Timer = case Timeout of infinity -> none; _ -> {Ticket, erlang:send_after(Timeout, self(), {read_timeout, Ticket})} end,
    #{mode => Mode, from => From, caller => Caller, ticket => Ticket, monitor => monitor(process, Caller), timer => Timer}.
finish(Key, Result, State) ->
    case maps:get(Key, State) of
        none -> State;
        W ->
            cancel_timer(maps:get(timer, W)), demonitor(maps:get(monitor, W), [flush]),
            case {Result, maps:get(mode, W)} of
                {cancelled, _} -> ok;
                {_, sync} when Key =:= reader -> gen_server:reply(maps:get(from, W), {ok, Result});
                {_, sync} -> gen_server:reply(maps:get(from, W), Result);
                {_, async} -> maps:get(caller, W) ! {lawspec_channel, self(), maps:get(ticket, W), Result}
            end,
            State#{Key := none}
    end.
cancel_timer(none) -> ok;
cancel_timer({_, Timer}) -> erlang:cancel_timer(Timer), ok.

update({Protocol, Frames}, State) ->
    Node = maps:get(node, State),
    lists:foreach(fun(Frame) -> _ = lawspec_beam_node:forward(Node, Frame) end, Frames),
    schedule(wake(State#{protocol := Protocol})).
wake(State = #{taking := Taking, protocol := Protocol}) when Taking =/= none ->
    case lawspec_beam_channel_protocol:take_status(Protocol, now_us()) of
        waiting -> State;
        ready -> finish(taking, {ok, ok}, State);
        {error, _} = Error -> finish(taking, Error, State)
    end;
wake(State = #{reader := Reader, protocol := Protocol}) when Reader =/= none ->
    case lawspec_beam_channel_protocol:receive_body(Protocol) of
        {empty, _} -> State;
        {Result, Next} -> finish(reader, Result, State#{protocol := Next})
    end;
wake(State) -> State.
schedule(State = #{timer := Timer, protocol := Protocol}) ->
    Active = maps:get(failure, Protocol) =:= none andalso maps:get(moved, Protocol) =:= none andalso
        (map_size(maps:get(unacked, Protocol)) > 0 orelse maps:get(taking, State) =/= none orelse
         (maps:get(taking, Protocol) =/= none andalso not maps:get(taken, Protocol)) orelse
         (maps:get(announcing, Protocol) andalso not maps:get(confirmed, Protocol) andalso maps:get(peer, Protocol) =/= none)),
    case {Active, Timer} of
        {true, none} ->
            Ref = make_ref(), State#{timer := {Ref, erlang:send_after(10, self(), {tick, Ref})}};
        {false, _} -> cancel_timer(Timer), State#{timer := none};
        _ -> State
    end.
