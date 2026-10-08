%% @doc Pure transitions for a reliable, movable network channel end.
%% Timers and packet transport belong to its owning process. Application
%% values enter as canonical bytes and leave in send order, exactly once.
%% Times are monotonic microseconds; their epoch may be negative on BEAM.
%% ref:DEC-distribution-canonical-wire ref:DEC-sessions-by-construction
-module(lawspec_beam_channel_protocol).
-export([new/2, connect/3, send/3, abandon/2, receive_body/1, accept/3, tick/2,
    offer/2, take/3, take_status/2]).
-define(RETRY, 50000).

new(Address, Deadline) when is_binary(Address), is_integer(Deadline), Deadline > 0 ->
    _ = lawspec_beam_wire:split_address(Address),
    #{address => Address, deadline => Deadline, peer => none, out => 0, expected => 0,
        unacked => #{}, early => #{}, received => queue:new(), failure => none,
        closed => false, used => false, history => [], token => none, moved => none,
        snapshot => none, taking => none, taken => false, confirmed => false,
        announcing => false, announced_at => none}.
connect(State, Peer, Now) ->
    usable(State), true = maps:get(peer, State) =:= none,
    _ = lawspec_beam_wire:split_address(Peer),
    transmit(State#{peer := Peer}, -1, <<"hello">>, Now).
send(State = #{out := Sequence}, Bytes, Now) when is_binary(Bytes) ->
    usable(State),
    transmit(State#{out := Sequence + 1, used := true}, Sequence, <<0, Bytes/binary>>, Now).
abandon(State = #{closed := true}, _) -> {State, []};
abandon(State = #{moved := Moved}, _) when Moved =/= none -> {State, []};
abandon(State = #{out := Sequence}, Now) ->
    case maps:get(failure, State) of
        none -> transmit(State#{out := Sequence + 1, closed := true}, Sequence, <<1>>, Now);
        _ -> {State#{closed := true}, []}
    end.
usable(State) ->
    case {maps:get(failure, State), maps:get(closed, State), maps:get(token, State), maps:get(moved, State),
            maps:get(taking, State), maps:get(taken, State)} of
        {none, false, none, none, none, _} -> ok;
        {none, false, none, none, _, true} -> ok;
        _ -> error({lawspec, channel_end_unavailable})
    end.
transmit(State = #{unacked := Unacked}, Sequence, Body, Now) ->
    %% Constructing the canonical payload enforces the signed 64-bit range.
    Frame = channel_frame(State, Sequence, Body),
    S1 = State#{unacked := Unacked#{Sequence => #{body => Body, first => Now, last => Now}}},
    {S1, case maps:get(peer, State) of none -> []; _ -> [Frame] end}.
channel_frame(State, Sequence, Body) ->
    message(maps:get(peer, State), <<"chan">>, lawspec_beam_wire:channel(Sequence, maps:get(address, State), Body)).
message(To, Kind, Payload) -> #{to => To, kind => Kind, payload => Payload}.

receive_body(State = #{token := Token, moved := Moved}) when Token =/= none; Moved =/= none ->
    {{error, <<"the channel end has been offered or moved">>}, State};
receive_body(State = #{received := Received}) ->
    case queue:out(Received) of
        {{value, <<0, Body/binary>>}, Rest} -> {{value, Body}, State#{received := Rest, used := true}};
        {{value, <<1>>}, _} ->
            Reason = <<"the other end gave up the conversation">>,
            {{error, Reason}, fail(Reason, State#{received := queue:new(), used := true})};
        {empty, _} ->
            case maps:get(failure, State) of
                none -> {empty, State};
                Reason -> {{error, Reason}, State}
            end
    end.

%% Invalid control frames do not corrupt an end or crash its owner. The
%% sender keeps retransmitting valid frames until they are acknowledged.
accept(State, Frame, Now) ->
    try arriving(State, Frame, Now) catch _:_ -> {State, []} end.
arriving(State, #{kind := <<"take">>, payload := Payload}, _) -> give(State, Payload);
arriving(State = #{moved := To}, Frame, _) when To =/= none ->
    {State, [Frame#{to => To}]};
arriving(State = #{taking := Taking, taken := false}, Frame, Now) when Taking =/= none ->
    case Frame of
        #{kind := <<"state">>, payload := Payload} -> install(State, Payload, Now);
        _ -> {State, []}
    end;
arriving(State = #{failure := Failure}, #{kind := <<"chan">>}, _) when Failure =/= none -> {State, []};
arriving(State = #{unacked := Unacked}, #{kind := <<"ack">>, payload := Payload}, _) ->
    Sequence = lawspec_beam_wire:read_sequence(Payload), {State#{unacked := maps:remove(Sequence, Unacked)}, []};
arriving(State, #{kind := <<"moved">>, payload := Payload}, _) -> peer_moved(State, Payload);
arriving(State, #{kind := <<"moved-ack">>, payload := Payload}, _) ->
    {[Address], <<>>} = lawspec_beam_wire:read_fields([text_type()], Payload, #{}),
    case maps:get(address, State) of Address -> {State#{confirmed := true}, []}; _ -> {State, []} end;
arriving(State, #{kind := <<"chan">>, payload := Payload}, _) ->
    {Sequence, Sender, Body} = lawspec_beam_wire:read_channel(Payload),
    _ = lawspec_beam_wire:split_address(Sender),
    Updated = case Sequence of
        -1 ->
            <<"hello">> = Body,
            case maps:get(peer, State) of none -> State#{peer := Sender}; _ -> State end;
        _ when Sequence >= 0 ->
            true = valid_body(Body),
            Expected = maps:get(expected, State), Early = maps:get(early, State),
            case Sequence >= Expected andalso not maps:is_key(Sequence, Early) of
                true -> drain(State#{early := Early#{Sequence => Body}});
                false -> State
            end
    end,
    {Updated, [message(Sender, <<"ack">>, lawspec_beam_wire:sequence(Sequence))]};
arriving(State, _, _) -> {State, []}.
valid_body(<<0, _/binary>>) -> true;
valid_body(<<1>>) -> true;
valid_body(_) -> false.
drain(State = #{expected := Expected, early := Early, received := Received}) ->
    case maps:take(Expected, Early) of
        error -> State;
        {Body, Rest} -> drain(State#{expected := Expected + 1, early := Rest, received := queue:in(Body, Received)})
    end.

tick(State = #{moved := Moved}, _) when Moved =/= none -> {State, []};
tick(State = #{failure := Failure}, _) when Failure =/= none -> {State, []};
tick(State = #{taking := Taking, taken := false}, Now) when Taking =/= none ->
    #{first := First, last := Last, address := Old, token := Token} = Taking,
    case Now - First >= maps:get(deadline, State) of
        true -> {fail(take_failure(), State), []};
        false when Now - Last > ?RETRY ->
            Payload = lawspec_beam_wire:fields([text_type(), text_type()], [Token, maps:get(address, State)], #{}),
            {State#{taking := Taking#{last := Now}}, [message(Old, <<"take">>, Payload)]};
        false -> {State, []}
    end;
tick(State = #{unacked := Unacked, peer := Peer}, Now) ->
    Due = [{N, E} || {N, E = #{last := Last}} <- lists:sort(maps:to_list(Unacked)), Now - Last > ?RETRY],
    Stale = lists:any(fun({_, #{first := First}}) -> Now - First > maps:get(deadline, State) end, Due),
    case Stale of
        true -> {fail(<<"the other end did not answer in time (unreachable)">>, State), []};
        false when Peer =:= none -> {State, []};
        false ->
            {S1, Announce} = announce(State, Now),
            Frames = [channel_frame(S1, N, maps:get(body, E)) || {N, E} <- Due],
            Updated = lists:foldl(fun({N, E}, Acc) -> Acc#{N := E#{last := Now}} end, Unacked, Due),
            {S1#{unacked := Updated}, Announce ++ Frames}
    end.
announce(State = #{announcing := true, confirmed := false, announced_at := Last}, Now)
        when Last =:= none; Now - Last > ?RETRY ->
    Payload = lawspec_beam_wire:fields([[<<"list">>, text_type()], text_type()],
        [maps:get(history, State), maps:get(address, State)], #{}),
    {State#{announced_at := Now}, [message(maps:get(peer, State), <<"moved">>, Payload)]};
announce(State, _) -> {State, []}.
fail(Reason, State = #{failure := none}) -> State#{failure := Reason, unacked := #{}};
fail(_, State) -> State.

offer(State, Token) when is_binary(Token), byte_size(Token) > 0 ->
    true = not maps:get(used, State), true = not maps:get(closed, State), true = maps:get(moved, State) =:= none,
    true = maps:get(taking, State) =:= none orelse maps:get(taken, State),
    Chosen = case maps:get(token, State) of none -> Token; Existing -> Existing end,
    {<<(maps:get(address, State))/binary, "?take=", Chosen/binary>>, State#{token := Chosen}}.
take(State, Address, Now) ->
    usable(State), true = not maps:get(used, State),
    [Old, Token] = binary:split(Address, <<"?take=">>), true = byte_size(Token) > 0,
    _ = lawspec_beam_wire:split_address(Old),
    tick(State#{taking := #{address => Old, token => Token, first => Now, last => Now - ?RETRY - 1}}, Now).
take_status(#{taking := none}, _) -> ready;
take_status(State = #{taking := #{first := First}, taken := Taken}, Now) ->
    case Taken of
        true -> case maps:get(confirmed, State) orelse maps:get(failure, State) =/= none orelse Now - First >= maps:get(deadline, State) of
            true -> ready; false -> waiting end;
        false -> case maps:get(failure, State) =/= none orelse Now - First >= maps:get(deadline, State) of
            true -> {error, take_failure()}; false -> waiting end
    end.
take_failure() -> <<"the node the end came from did not hand it over in time (unreachable)">>.

give(State, Payload) ->
    {[Token, Taker], <<>>} = lawspec_beam_wire:read_fields([text_type(), text_type()], Payload, #{}),
    _ = lawspec_beam_wire:split_address(Taker),
    case maps:get(token, State) =:= Token andalso Token =/= none of
        false -> {State, []};
        true -> case maps:get(moved, State) of
            none ->
                Snapshot = snapshot(State),
                {State#{moved := Taker, snapshot := Snapshot, unacked := #{}, early := #{}},
                    [message(Taker, <<"state">>, Snapshot)]};
            Taker -> {State, [message(Taker, <<"state">>, maps:get(snapshot, State))]};
            _ -> {State, []}
        end
    end.
snapshot(State) ->
    Prefix = lawspec_beam_wire:fields([text_type(), text_type(), text_type(), [<<"list">>, text_type()], seq_type(), seq_type()],
        [maps:get(token, State), empty(maps:get(failure, State)), empty(maps:get(peer, State)),
         maps:get(history, State) ++ [maps:get(address, State)], maps:get(out, State), maps:get(expected, State)], #{}),
    Unacked = [{N, maps:get(body, E)} || {N, E} <- lists:sort(maps:to_list(maps:get(unacked, State)))],
    Early = lists:sort(maps:to_list(maps:get(early, State))),
    Received = lawspec_beam_values:encode([<<"list">>, bytes_type()], queue:to_list(maps:get(received, State)), #{}),
    iolist_to_binary([Prefix, numbered(Unacked), numbered(Early), Received]).
numbered(Entries) -> [lawspec_beam_values:varint(length(Entries)),
    [lawspec_beam_wire:fields([seq_type(), bytes_type()], [N, Body], #{}) || {N, Body} <- Entries]].
read_numbered(Bytes) ->
    {Count, Rest} = lawspec_beam_values:read_varint(Bytes), true = Count =< byte_size(Rest) div 2,
    lists:mapfoldl(fun(_, B) ->
        {[N, Body], After} = lawspec_beam_wire:read_fields([seq_type(), bytes_type()], B, #{}), {{N, Body}, After}
    end, Rest, lists:seq(1, Count)).
read_binaries(Type, Bytes) ->
    {Count, Rest} = lawspec_beam_values:read_varint(Bytes), true = Count =< byte_size(Rest),
    lists:mapfoldl(fun(_, B) -> lawspec_beam_values:decode_prefix(Type, B, #{}) end, Rest, lists:seq(1, Count)).
install(State = #{taking := #{token := Token, address := Old}}, Payload, Now) ->
    {[Token, Failure, Peer], R1} = lawspec_beam_wire:read_fields([text_type(), text_type(), text_type()], Payload, #{}),
    {History, R2} = read_binaries(text_type(), R1),
    Old = lists:last(History),
    lists:foreach(fun lawspec_beam_wire:split_address/1, History),
    case Peer of <<>> -> ok; _ -> lawspec_beam_wire:split_address(Peer) end,
    {[Out, Expected], R3} = lawspec_beam_wire:read_fields([seq_type(), seq_type()], R2, #{}),
    true = Out >= 0 andalso Expected >= 0,
    {Unacked, R4} = read_numbered(R3), {Early, R5} = read_numbered(R4),
    {Received, <<>>} = read_binaries(bytes_type(), R5),
    true = lists:all(fun valid_body/1, Received),
    true = lists:all(fun({N, B}) -> N >= Expected andalso valid_body(B) end, Early),
    true = lists:all(fun({N, B}) -> (N =:= -1 andalso B =:= <<"hello">>) orelse (N >= 0 andalso N < Out andalso valid_body(B)) end, Unacked),
    true = map_size(maps:from_list(Unacked)) =:= length(Unacked),
    true = map_size(maps:from_list(Early)) =:= length(Early),
    Pend = maps:from_list([{N, #{body => B, first => Now, last => Now - ?RETRY - 1}} || {N, B} <- Unacked]),
    S1 = State#{peer := optional(Peer), history := History, out := Out, expected := Expected,
        unacked := Pend, early := maps:from_list(Early), received := queue:from_list(Received),
        announcing := true, announced_at := none, taken := true},
    case Failure of <<>> -> tick(drain(S1), Now); _ -> {fail(Failure, S1), []} end.
peer_moved(State, Payload) ->
    {History, Rest} = read_binaries(text_type(), Payload),
    {[To], <<>>} = lawspec_beam_wire:read_fields([text_type()], Rest, #{}),
    _ = lawspec_beam_wire:split_address(To),
    Peer = maps:get(peer, State),
    S1 = case Peer =:= none orelse lists:member(Peer, History) of true -> State#{peer := To}; false -> State end,
    case maps:get(peer, S1) of
        To -> {S1, [message(To, <<"moved-ack">>, lawspec_beam_values:encode(text_type(), To, #{}))]};
        _ -> {S1, []}
    end.
empty(none) -> <<>>;
empty(Value) -> Value.
optional(<<>>) -> none;
optional(Value) -> Value.
text_type() -> [<<"text">>].
bytes_type() -> [<<"bytes">>].
seq_type() -> [<<"int">>, <<"Int64">>, -16#8000000000000000, 16#7fffffffffffffff].
