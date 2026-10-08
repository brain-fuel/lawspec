%% @doc Reliable delivery and transferable state survive packet faults.
%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(lawspec_beam_channel_protocol_tests).
-include_lib("eunit/include/eunit.hrl").
-export([vectors/1]).

new(Name) -> lawspec_beam_channel_protocol:new(<<"mem://", Name/binary, "/end">>, 5000000).
deliver(State, Frame, Now) ->
    lawspec_beam_channel_protocol:accept(State, maps:merge(#{source => <<"mem://sender">>, id => 0}, Frame), Now).
connected() ->
    {B, [Hello]} = lawspec_beam_channel_protocol:connect(new(<<"b">>), <<"mem://a/end">>, 0),
    {A, [Ack]} = deliver(new(<<"a">>), Hello, 0),
    {ReadyB, []} = deliver(B, Ack, 0), {A, ReadyB}.
pop(State, Expected) ->
    {Result, Next} = lawspec_beam_channel_protocol:receive_body(State), ?assertEqual(Expected, Result), Next.

sends_before_hello_wait_for_a_peer_test() ->
    {A0, []} = lawspec_beam_channel_protocol:send(new(<<"a">>), <<"first">>, -100000),
    {B0, [Hello]} = lawspec_beam_channel_protocol:connect(new(<<"b">>), <<"mem://a/end">>, -80000),
    {A1, [Ack]} = deliver(A0, Hello, -80000),
    {B1, []} = deliver(B0, Ack, -80000),
    {A2, [Value]} = lawspec_beam_channel_protocol:tick(A1, -49999),
    {B2, [ValueAck]} = deliver(B1, Value, -49998),
    {A3, []} = deliver(A2, ValueAck, -49997),
    ?assertEqual(#{}, maps:get(unacked, A3)),
    _ = pop(pop(B2, {value, <<"first">>}), empty).

reordering_and_duplicates_deliver_once_in_send_order_test() ->
    {A0, B0} = connected(),
    {A1, [F0]} = lawspec_beam_channel_protocol:send(A0, <<"zero">>, 0),
    {A2, [F1]} = lawspec_beam_channel_protocol:send(A1, <<"one">>, 1),
    {A3, [F2]} = lawspec_beam_channel_protocol:send(A2, <<"two">>, 2),
    {A4, B4} = lists:foldl(fun(Frame, {A, B}) ->
        {NextB, [Ack]} = deliver(B, Frame, 3), {NextA, []} = deliver(A, Ack, 3), {NextA, NextB}
    end, {A3, B0}, [F2, F2, F0, F1, F0, F1]),
    ?assertEqual(#{}, maps:get(unacked, A4)),
    _ = pop(pop(pop(pop(B4, {value, <<"zero">>}), {value, <<"one">>}), {value, <<"two">>}), empty).

abandonment_follows_all_accepted_values_test() ->
    {A0, B0} = connected(),
    {A1, [Value]} = lawspec_beam_channel_protocol:send(A0, <<"kept">>, 0),
    {A2, [Closed]} = lawspec_beam_channel_protocol:abandon(A1, 1),
    ?assertEqual({A2, []}, lawspec_beam_channel_protocol:abandon(A2, 2)),
    {B1, [_]} = deliver(B0, Closed, 2),
    _ = pop(B1, empty),
    {B2, [_]} = deliver(B1, Value, 3),
    Reason = <<"the other end gave up the conversation">>,
    B3 = pop(pop(B2, {value, <<"kept">>}), {error, Reason}),
    _ = pop(B3, {error, Reason}),
    ?assertError({lawspec, channel_end_unavailable}, lawspec_beam_channel_protocol:send(A2, <<>>, 3)).

retries_use_monotonic_differences_and_stop_after_deadline_test() ->
    Epoch = -576460000000000,
    {A, [First]} = lawspec_beam_channel_protocol:connect(new(<<"a">>), <<"mem://b/end">>, Epoch),
    ?assertEqual({A, []}, lawspec_beam_channel_protocol:tick(A, Epoch + 50000)),
    {A1, [First]} = lawspec_beam_channel_protocol:tick(A, Epoch + 50001),
    {A2, []} = lawspec_beam_channel_protocol:tick(A1, Epoch + 5000001),
    ?assertMatch({{error, _}, _}, lawspec_beam_channel_protocol:receive_body(A2)),
    Late = #{kind => <<"chan">>, payload => lawspec_beam_wire:channel(0, <<"mem://b/end">>, <<0, "late">>)},
    ?assertEqual({A2, []}, deliver(A2, Late, Epoch + 6000000)).

receiving_eof_keeps_outbound_data_and_eof_retries_alive_test() ->
    {A0, B0} = connected(),
    %% A's value and EOF are lost, while B's EOF reaches A first.
    {A1, [_]} = lawspec_beam_channel_protocol:send(A0, <<"accepted">>, 0),
    {A2, [AClosed]} = lawspec_beam_channel_protocol:abandon(A1, 1),
    {B1, [BClosed]} = lawspec_beam_channel_protocol:abandon(B0, 2),
    {A3, [BAck]} = deliver(A2, BClosed, 3),
    {B2, []} = deliver(B1, BAck, 4),
    A4 = pop(A3, {error, <<"the other end gave up the conversation">>}),
    {A5, [Value, AClosed]} = lawspec_beam_channel_protocol:tick(A4, 50002),
    {B3, [ValueAck]} = deliver(B2, Value, 50003),
    {B4, [_LostEofAck]} = deliver(B3, AClosed, 50004),
    {A6, []} = deliver(A5, ValueAck, 50005),
    B5 = pop(pop(B4, {value, <<"accepted">>}), {error, <<"the other end gave up the conversation">>}),
    %% Even after consuming EOF, B must acknowledge its retransmission.
    {A7, [AClosed]} = lawspec_beam_channel_protocol:tick(A6, 100004),
    {B5, [Ack]} = deliver(B5, AClosed, 100005),
    {A8, []} = deliver(A7, Ack, 100006),
    ?assertEqual(#{}, maps:get(unacked, A8)),
    ?assertEqual({A8, []}, lawspec_beam_channel_protocol:tick(A8, 10000000)).

handoff_carries_queues_retries_and_late_frames_test() ->
    %% A has not used its end, but B has already sent ahead. Its hello is
    %% still unacknowledged; value 2 arrives before value 1.
    {A0, [_]} = lawspec_beam_channel_protocol:connect(new(<<"a">>), <<"mem://b/end">>, 0),
    {_, B0} = connected(),
    {B1, [F0]} = lawspec_beam_channel_protocol:send(B0, <<"zero">>, 1),
    {B2, [F1]} = lawspec_beam_channel_protocol:send(B1, <<"one">>, 2),
    {B3, [F2]} = lawspec_beam_channel_protocol:send(B2, <<"two">>, 3),
    {A1, [_]} = deliver(A0, F0, 4), {A2, [_]} = deliver(A1, F2, 4),
    {Address, Offered} = lawspec_beam_channel_protocol:offer(A2, <<"secret">>),
    ?assertError({lawspec, channel_end_unavailable}, lawspec_beam_channel_protocol:send(Offered, <<>>, 5)),
    {C0, [Take]} = lawspec_beam_channel_protocol:take(new(<<"c">>), Address, 5),
    {Moved, [Snapshot]} = deliver(Offered, Take, 6),
    {C1, [MovedNotice, NewHello]} = deliver(C0, Snapshot, 7),
    ?assertEqual(<<"moved">>, maps:get(kind, MovedNotice)),
    ?assertMatch({-1, <<"mem://c/end">>, <<"hello">>}, lawspec_beam_wire:read_channel(maps:get(payload, NewHello))),
    ?assertEqual(waiting, lawspec_beam_channel_protocol:take_status(C1, 7)),
    {B4, [MovedAck]} = deliver(B3, MovedNotice, 8),
    {C2, []} = deliver(C1, MovedAck, 9),
    ?assertEqual(ready, lawspec_beam_channel_protocol:take_status(C2, 9)),
    {Moved, [Forwarded]} = deliver(Moved, F1#{source => <<"mem://b">>, id => 42}, 10),
    ?assertMatch(#{to := <<"mem://c/end">>, source := <<"mem://b">>, id := 42}, Forwarded),
    {C3, [_]} = deliver(C2, Forwarded, 11),
    C4 = pop(pop(pop(C3, {value, <<"zero">>}), {value, <<"one">>}), {value, <<"two">>}),
    {_, [F3]} = lawspec_beam_channel_protocol:send(B4, <<"direct">>, 12),
    ?assertEqual(<<"mem://c/end">>, maps:get(to, F3)),
    {C5, [_]} = deliver(C4, F3, 13), _ = pop(C5, {value, <<"direct">>}),
    ?assertEqual({Moved, []}, lawspec_beam_channel_protocol:tick(Moved, 10000000)),
    ?assertEqual({Moved, []}, lawspec_beam_channel_protocol:abandon(Moved, 10000000)).

take_token_has_one_recipient_and_replies_idempotently_test() ->
    {Address, A} = lawspec_beam_channel_protocol:offer(new(<<"a">>), <<"token">>),
    {_, [C]} = lawspec_beam_channel_protocol:take(new(<<"c">>), Address, 0),
    {_, [D]} = lawspec_beam_channel_protocol:take(new(<<"d">>), Address, 0),
    {_, [Wrong]} = lawspec_beam_channel_protocol:take(new(<<"c">>), <<"mem://a/end?take=wrong">>, 0),
    ?assertEqual({A, []}, deliver(A, Wrong, 1)),
    {A1, [Snapshot]} = deliver(A, C, 1),
    ?assertEqual({A1, [Snapshot]}, deliver(A1, C, 2)),
    ?assertEqual({A1, []}, deliver(A1, D, 2)),
    ?assertEqual({Address, A}, lawspec_beam_channel_protocol:offer(A, <<"ignored">>)).

take_retries_timeout_and_relay_fallback_test() ->
    {Address, A} = lawspec_beam_channel_protocol:offer(new(<<"a">>), <<"token">>),
    {C0, [Take]} = lawspec_beam_channel_protocol:take(new(<<"c">>), Address, -10000000),
    {C1, [Take]} = lawspec_beam_channel_protocol:tick(C0, -9949999),
    {Failed, []} = lawspec_beam_channel_protocol:tick(C1, -5000000),
    ?assertMatch({error, _}, lawspec_beam_channel_protocol:take_status(Failed, -5000000)),
    {_, [Snapshot]} = deliver(A, Take, -9949998),
    {C2, []} = deliver(C1, Snapshot, -9949997),
    %% No peer exists yet to confirm a move: return a live end at the
    %% deadline, with the old address continuing to forward late frames.
    ?assertEqual(waiting, lawspec_beam_channel_protocol:take_status(C2, -9949997)),
    ?assertEqual(ready, lawspec_beam_channel_protocol:take_status(C2, -5000000)).

older_move_cannot_roll_back_a_newer_peer_address_test() ->
    {A, _} = connected(),
    Move = fun(History, To) -> #{kind => <<"moved">>, payload => lawspec_beam_wire:fields(
        [[<<"list">>, [<<"text">>]], [<<"text">>]], [History, To], #{})} end,
    {A1, [_]} = deliver(A, Move([<<"mem://b/end">>, <<"mem://c/end">>], <<"mem://d/end">>), 0),
    ?assertEqual({A1, []}, deliver(A1, Move([<<"mem://b/end">>], <<"mem://c/end">>), 1)),
    ?assertEqual(<<"mem://d/end">>, maps:get(peer, A1)).

malformed_control_frames_leave_state_intact_test() ->
    {A, _} = connected(),
    lists:foreach(fun(Kind) -> lists:foreach(fun(Bytes) ->
        ?assertEqual({A, []}, deliver(A, #{kind => Kind, payload => Bytes}, 0))
    end, [<<>>, <<255>>, <<0, 0, 0, 0, 0>>]) end,
        [<<"chan">>, <<"take">>, <<"moved">>, <<"moved-ack">>, <<"state">>]),
    {Address, Offered} = lawspec_beam_channel_protocol:offer(new(<<"a">>), <<"token">>),
    {C, [Take]} = lawspec_beam_channel_protocol:take(new(<<"c">>), Address, 0),
    {_, [Snapshot]} = deliver(Offered, Take, 1),
    Payload = maps:get(payload, Snapshot),
    ?assertEqual({C, []}, deliver(C, Snapshot#{payload := <<Payload/binary, 0>>}, 2)).

real_packet_faults_keep_both_directions_ordered_test_() ->
    {timeout, 10, fun() -> with_endpoints(fun(Net, A, B, _) ->
        lists:foreach(fun(I) ->
            ok = command(A, {send, <<I>>}), ok = command(B, {send, <<(255 - I)>>})
        end, lists:seq(1, 100)),
        ok = command(A, abandon), ok = command(B, abandon),
        ?assertEqual([<<I>> || I <- lists:seq(1, 100)], receive_n(B, 100)),
        ?assertEqual([<<(255 - I)>> || I <- lists:seq(1, 100)], receive_n(A, 100)),
        ?assertMatch({error, _}, wait_value(A)), ?assertMatch({error, _}, wait_value(B)),
        Trace = lawspec_beam_memory_network:trace(Net),
        ?assert(lists:any(fun(E) -> maps:get(outcome, E) =:= lost end, Trace)),
        ?assert(lists:any(fun(E) -> length(maps:get(delay_slots, E, [])) =:= 2 end, Trace))
    end) end}.

real_handoff_survives_closing_the_old_node_test_() ->
    {timeout, 10, fun() -> with_endpoints(fun(_, A, B, C) ->
        lists:foreach(fun(I) -> ok = command(B, {send, <<I>>}) end, lists:seq(1, 10)),
        Address = command(A, {offer, <<"one-time-token">>}),
        ok = command(C, {take, Address}),
        wait_ready(C, erlang:monotonic_time(millisecond) + 3000),
        stop_endpoint(A),
        lists:foreach(fun(I) -> ok = command(B, {send, <<I>>}) end, lists:seq(11, 40)),
        ok = command(B, abandon),
        ?assertEqual([<<I>> || I <- lists:seq(1, 40)], receive_n(C, 40)),
        ?assertMatch({error, _}, wait_value(C))
    end) end}.

%% The test drivers only own protocol state and send canonical frames over
%% the real memory transport. They add no ordering or delivery guarantees.
with_endpoints(Body) ->
    lawspec_beam_memory_network:with_network(#{seed => 815, loss => 0.2, duplicate => 0.4, delay => 0.003, record => true}, fun(Net) ->
        A = endpoint(Net, <<"a">>, none), B = endpoint(Net, <<"b">>, <<"mem://a/end">>), C = endpoint(Net, <<"c">>, none),
        try Body(Net, A, B, C) after lists:foreach(fun stop_endpoint/1, [A, B, C]) end
    end).
endpoint(Net, Name, Peer) ->
    Owner = self(), Ref = make_ref(),
    Pid = spawn(fun() ->
        Address = <<"mem://", Name/binary>>, OM = monitor(process, Owner), NM = monitor(process, Net),
        ok = lawspec_beam_memory_network:register(Net, Address, self()),
        try
            {State, Frames} = case Peer of
                none -> {new(Name), []};
                _ -> lawspec_beam_channel_protocol:connect(new(Name), Peer, erlang:monotonic_time(microsecond))
            end,
            transmit(Net, Address, Frames), erlang:send_after(5, self(), tick),
            Owner ! {ready, Ref, self()}, endpoint_loop(Net, Address, State, OM, NM)
        after try lawspec_beam_memory_network:unregister(Net, Address) catch exit:_ -> ok end end
    end),
    receive {ready, Ref, Pid} -> Pid after 1000 -> error(endpoint_not_started) end.
endpoint_loop(Net, Address, State, OM, NM) ->
    receive
        stop -> ok;
        {'DOWN', M, process, _, _} when M =:= OM; M =:= NM -> ok;
        tick ->
            {Next, Frames} = lawspec_beam_channel_protocol:tick(State, erlang:monotonic_time(microsecond)),
            transmit(Net, Address, Frames), erlang:send_after(5, self(), tick), endpoint_loop(Net, Address, Next, OM, NM);
        {lawspec_network, Net, _, Bytes} ->
            {ok, Frame} = lawspec_beam_wire:read_frame(Bytes),
            {Next, Frames} = lawspec_beam_channel_protocol:accept(State, Frame, erlang:monotonic_time(microsecond)),
            transmit(Net, Address, Frames), endpoint_loop(Net, Address, Next, OM, NM);
        {command, Caller, Ref, Request} ->
            Now = erlang:monotonic_time(microsecond),
            {Result, Next, Frames} = case Request of
                {send, Bytes} -> {S, Fs} = lawspec_beam_channel_protocol:send(State, Bytes, Now), {ok, S, Fs};
                abandon -> {S, Fs} = lawspec_beam_channel_protocol:abandon(State, Now), {ok, S, Fs};
                {offer, Token} -> {Value, S} = lawspec_beam_channel_protocol:offer(State, Token), {Value, S, []};
                {take, From} -> {S, Fs} = lawspec_beam_channel_protocol:take(State, From, Now), {ok, S, Fs};
                pop -> {Value, S} = lawspec_beam_channel_protocol:receive_body(State), {Value, S, []};
                take_status -> {lawspec_beam_channel_protocol:take_status(State, Now), State, []}
            end,
            transmit(Net, Address, Frames), Caller ! {result, Ref, Result}, endpoint_loop(Net, Address, Next, OM, NM)
    end.
transmit(Net, Address, Frames) -> lists:foreach(fun(F) ->
    {Node, Name} = lawspec_beam_wire:split_address(maps:get(to, F)),
    Bytes = lawspec_beam_wire:frame(maps:get(kind, F), Name, maps:get(source, F, Address), maps:get(id, F, 0), maps:get(payload, F)),
    _ = lawspec_beam_memory_network:send(Net, Address, Node, Bytes)
end, Frames).
command(Pid, Request) ->
    Ref = make_ref(), Pid ! {command, self(), Ref, Request},
    receive {result, Ref, Result} -> Result after 1000 -> error({endpoint_not_answering, Request}) end.
stop_endpoint(Pid) ->
    Ref = monitor(process, Pid), Pid ! stop,
    receive {'DOWN', Ref, process, Pid, _} -> ok after 1000 -> exit(Pid, kill), error(endpoint_leaked) end.
receive_n(Pid, N) -> [begin {value, V} = wait_value(Pid), V end || _ <- lists:seq(1, N)].
wait_value(Pid) -> wait_value(Pid, erlang:monotonic_time(millisecond) + 3000).
wait_value(Pid, Until) -> case command(Pid, pop) of
    empty -> true = erlang:monotonic_time(millisecond) < Until, receive after 1 -> ok end, wait_value(Pid, Until);
    Result -> Result
end.
wait_ready(Pid, Until) -> case command(Pid, take_status) of
    ready -> ok;
    waiting -> true = erlang:monotonic_time(millisecond) < Until, receive after 1 -> ok end, wait_ready(Pid, Until)
end.

vectors(Path) ->
    {ok, Bytes} = file:read_file(Path), Cases = json:decode(Bytes),
    lists:foreach(fun(C) ->
        Decode = fun(Items) -> [{N, base64:decode(B)} || [N, B] <- Items] end,
        Failure = case maps:get(<<"failure">>, C) of <<>> -> none; F -> F end,
        Peer = case maps:get(<<"peer">>, C) of <<>> -> none; P -> P end,
        State = (new(<<"a">>))#{token := maps:get(<<"token">>, C), failure := Failure, peer := Peer,
            history := maps:get(<<"history">>, C), out := maps:get(<<"out">>, C), expected := maps:get(<<"expected">>, C),
            unacked := maps:from_list([{N, #{body => B, first => 0, last => 0}} || {N, B} <- Decode(maps:get(<<"unacked">>, C))]),
            early := maps:from_list(Decode(maps:get(<<"early">>, C))),
            received := queue:from_list([base64:decode(B) || B <- maps:get(<<"received">>, C)])},
        Request = lawspec_beam_wire:fields([[<<"text">>], [<<"text">>]], [maps:get(<<"token">>, C), <<"mem://c/end">>], #{}),
        {_, [#{kind := <<"state">>, payload := Payload}]} = deliver(State, #{kind => <<"take">>, payload => Request}, 1),
        ?assertEqual(base64:decode(maps:get(<<"state">>, C)), Payload),
        Offer = <<"mem://a/end?take=", (maps:get(<<"token">>, C))/binary>>,
        {Taker, [_]} = lawspec_beam_channel_protocol:take(new(<<"c">>), Offer, -1000000),
        {Installed, _} = deliver(Taker, #{kind => <<"state">>, payload => Payload}, -999999),
        ?assert(maps:get(taken, Installed)),
        ?assertEqual(Failure, maps:get(failure, Installed)),
        ?assertEqual(Peer, maps:get(peer, Installed)),
        ?assertEqual(maps:get(out, State), maps:get(out, Installed)),
        ?assertEqual(maps:get(expected, State), maps:get(expected, Installed)),
        ?assertEqual(maps:get(early, State), maps:get(early, Installed)),
        ?assertEqual(queue:to_list(maps:get(received, State)), queue:to_list(maps:get(received, Installed))),
        ExpectedUnacked = case Failure of none -> maps:map(fun(_, E) -> maps:get(body, E) end, maps:get(unacked, State)); _ -> #{} end,
        ?assertEqual(ExpectedUnacked, maps:map(fun(_, E) -> maps:get(body, E) end, maps:get(unacked, Installed)))
    end, Cases),
    io:format("~B endpoint handoff states match the portable canonical bytes~n", [length(Cases)]).
