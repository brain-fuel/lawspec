%% @doc Native mailboxes retain accepted messages across receiver changes,
%% and network retries carry the canonical values exactly once.
%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(lawspec_beam_mailbox_tests).
-include_lib("eunit/include/eunit.hrl").

fifo_close_and_drain_test() ->
    lawspec_beam_mailbox:with_mailbox(fun(Box) ->
        [ok = lawspec_beam_mailbox:send(Box, V) || V <- [1, 2, 3]],
        ok = lawspec_beam_mailbox:close(Box),
        ?assertError({lawspec, {mailbox, closed}}, lawspec_beam_mailbox:send(Box, 4)),
        ?assertEqual([1, 2, 3], [lawspec_beam_mailbox:receive_value(Box) || _ <- lists:seq(1, 3)]),
        ?assertError({lawspec, {mailbox, closed}}, lawspec_beam_mailbox:receive_value(Box)),
        ok = lawspec_beam_mailbox:close(Box), ?assertNot(is_process_alive(Box))
    end).

timed_receive_does_not_steal_later_messages_test() ->
    lawspec_beam_mailbox:with_mailbox(fun(Box) ->
        ?assertEqual(nothing(), lawspec_beam_mailbox:receive_within(Box, 1000)),
        ok = lawspec_beam_mailbox:send(Box, ls_unit),
        ?assertEqual(just(ls_unit), lawspec_beam_mailbox:receive_within(Box, 0)),
        ?assertEqual(nothing(), lawspec_beam_mailbox:receive_within(Box, -10)),
        ?assertError({lawspec, {mailbox, invalid_duration}}, lawspec_beam_mailbox:receive_within(Box, invalid)),
        receive {_, {ok, _}} -> error(leaked_reply) after 0 -> ok end
    end).

blocking_receive_wakes_on_send_test() ->
    lawspec_beam_mailbox:with_mailbox(fun(Box) ->
        Parent = self(), {Pid, Ref} = spawn_monitor(fun() -> Parent ! {value, lawspec_beam_mailbox:receive_value(Box)} end),
        waiting(Box), ok = lawspec_beam_mailbox:send(Box, hello),
        receive {value, hello} -> ok after 1000 -> error(no_reply) end,
        receive {'DOWN', Ref, process, Pid, normal} -> ok after 1000 -> error(not_joined) end
    end).

concurrent_producers_preserve_each_senders_order_test() ->
    lawspec_beam_mailbox:with_mailbox(fun(Box) ->
        Workers = [spawn_monitor(fun() ->
            [ok = lawspec_beam_mailbox:send(Box, {I, J}) || J <- lists:seq(1, 50)]
        end) || I <- lists:seq(1, 8)],
        [receive {'DOWN', Ref, process, Pid, normal} -> ok after 1000 -> error(stuck_sender) end
            || {Pid, Ref} <- Workers],
        Values = [lawspec_beam_mailbox:receive_value(Box) || _ <- lists:seq(1, 400)],
        [?assertEqual(lists:seq(1, 50), [J || {K, J} <- Values, K =:= I]) || I <- lists:seq(1, 8)]
    end).

single_receiver_and_dead_caller_cleanup_test() ->
    lawspec_beam_mailbox:with_mailbox(fun(Box) ->
        {Pid, Ref} = spawn_monitor(fun() -> lawspec_beam_mailbox:receive_value(Box) end),
        waiting(Box),
        ?assertError({lawspec, {mailbox, already_receiving}}, lawspec_beam_mailbox:receive_within(Box, 0)),
        exit(Pid, kill), receive {'DOWN', Ref, process, Pid, killed} -> ok end,
        ok = lawspec_beam_mailbox:send(Box, retained),
        ?assertEqual(retained, lawspec_beam_mailbox:receive_value(Box))
    end).

close_wakes_reader_test() ->
    lawspec_beam_mailbox:with_mailbox(fun(Box) ->
        Parent = self(), {Pid, Ref} = spawn_monitor(fun() ->
            ?assertError({lawspec, {mailbox, closed}}, lawspec_beam_mailbox:receive_value(Box)), Parent ! closed
        end),
        waiting(Box), ok = lawspec_beam_mailbox:close(Box),
        receive closed -> ok after 1000 -> error(reader_stuck) end,
        receive {'DOWN', Ref, process, Pid, normal} -> ok end
    end).

full_duration_range_and_stale_timers_test() ->
    lawspec_beam_mailbox:with_mailbox(fun(Box) ->
        Parent = self(), {Pid, Ref} = spawn_monitor(fun() ->
            Parent ! {long, lawspec_beam_mailbox:receive_within(Box, 4611686018427387)}
        end),
        Reader = waiting(Box), ?assert(is_reference(maps:get(timer, Reader))),
        ok = lawspec_beam_mailbox:send(Box, kept),
        receive {long, Value} -> ?assertEqual(just(kept), Value) after 1000 -> error(no_long_reply) end,
        receive {'DOWN', Ref, process, Pid, normal} -> ok end,
        Box ! {read_timeout, maps:get(token, Reader)},
        ok = lawspec_beam_mailbox:send(Box, later),
        ?assertEqual(just(later), lawspec_beam_mailbox:receive_within(Box, 0))
    end).

virtual_clock_runs_in_caller_and_advances_only_when_empty_test() ->
    lawspec_beam_mailbox:with_mailbox(fun(Box) ->
        Parent = self(), Handler = lawspec_beam_effects:stateless(#{<<"sleep">> => fun(_, [Duration]) ->
            ?assertEqual(Parent, self()), Parent ! {slept, Duration},
            %% This would deadlock if the callback ran in the mailbox server.
            lawspec_beam_mailbox:send(Box, after_sleep), ls_unit
        end}),
        Schema = #{lawspec_handlers => #{<<"lawspec.time::ability::Clock">> => Handler}},
        ok = lawspec_beam_mailbox:send(Box, first),
        ?assertEqual(just(first), lawspec_beam_mailbox:receive_with_clock(Box, 10000000, Schema)),
        receive {slept, _} -> error(unnecessary_sleep) after 0 -> ok end,
        ?assertEqual(nothing(), lawspec_beam_mailbox:receive_with_clock(Box, 10000000, Schema)),
        receive {slept, {ls_data, _, [10000000]}} -> ok after 0 -> error(no_virtual_sleep) end,
        ?assertEqual(after_sleep, lawspec_beam_mailbox:receive_value(Box))
    end).

real_clock_waits_for_message_test() ->
    lawspec_beam_mailbox:with_mailbox(fun(Box) ->
        Handler = lawspec_beam_defaults:handler(<<"lawspec.time::ability::Clock">>),
        Schema = #{lawspec_handlers => #{<<"lawspec.time::ability::Clock">> => Handler}},
        Parent = self(), {Pid, Ref} = spawn_monitor(fun() ->
            Parent ! {clock_value, lawspec_beam_mailbox:receive_with_clock(Box, 1000000, Schema)}
        end),
        waiting(Box), ok = lawspec_beam_mailbox:send(Box, arrived),
        receive {clock_value, Result} -> ?assertEqual(just(arrived), Result) after 1000 -> error(no_real_receive) end,
        receive {'DOWN', Ref, process, Pid, normal} -> ok end
    end).

failed_clock_callback_keeps_mailbox_available_test() ->
    lawspec_beam_mailbox:with_mailbox(fun(Box) ->
        Handler = lawspec_beam_effects:stateless(#{<<"sleep">> => fun(_, _) -> error(clock_failed) end}),
        Schema = #{lawspec_handlers => #{<<"lawspec.time::ability::Clock">> => Handler}},
        ?assertError(clock_failed, lawspec_beam_mailbox:receive_with_clock(Box, 1, Schema)),
        ok = lawspec_beam_mailbox:send(Box, retained),
        ?assertEqual(retained, lawspec_beam_mailbox:receive_value(Box)),
        ok = lawspec_beam_mailbox:close(Box),
        ?assertError({lawspec, {mailbox, closed}}, lawspec_beam_mailbox:receive_with_clock(Box, 1, Schema))
    end).

detached_mailbox_survives_creator_test() ->
    Parent = self(), {Pid, Ref} = spawn_monitor(fun() -> Parent ! {box, lawspec_beam_mailbox:open()} end),
    Box = receive {box, B} -> B end,
    receive {'DOWN', Ref, process, Pid, normal} -> ok end,
    try ok = lawspec_beam_mailbox:send(Box, retained),
        ?assertEqual(retained, lawspec_beam_mailbox:receive_value(Box))
    after lawspec_beam_mailbox:stop(Box) end.

scoped_mailbox_joins_on_failure_and_owner_death_test() ->
    Parent = self(),
    ?assertError(probe, lawspec_beam_mailbox:with_mailbox(fun(Box) -> Parent ! {failed_box, Box}, error(probe) end)),
    receive {failed_box, Box} -> ?assertNot(is_process_alive(Box)) end,
    {Pid, Ref} = spawn_monitor(fun() -> lawspec_beam_mailbox:with_mailbox(fun(B) -> Parent ! {owned_box, B}, receive wait -> ok end end) end),
    Owned = receive {owned_box, B} -> B end, Monitor = monitor(process, Owned),
    exit(Pid, kill), receive {'DOWN', Ref, process, Pid, killed} -> ok end,
    receive {'DOWN', Monitor, process, Owned, normal} -> ok after 1000 -> error(leaked_mailbox) end.

remote_mailbox_deduplicates_faulty_delivery_test_() ->
    {timeout, 20, fun() -> with_network(#{seed => 828, loss => 0.2, duplicate => 0.4, delay => 0.002, record => true},
        fun(Net, A, B) ->
            Box = lawspec_beam_mailbox:serve(A, <<"jobs">>, <<"(int Int64 -1000 1000)">>),
            Sender = lawspec_beam_mailbox:connect(B, lawspec_beam_mailbox:address(Box), <<"(int Int64 -1000 1000)">>, 3000),
            [ok = lawspec_beam_mailbox:send_remote(Sender, I) || I <- lists:seq(1, 20)],
            ?assertEqual(lists:seq(1, 20), [lawspec_beam_mailbox:receive_value(Box) || _ <- lists:seq(1, 20)]),
            ?assertEqual(nothing(), lawspec_beam_mailbox:receive_within(Box, 20000)),
            ok = lawspec_beam_mailbox:close(Box),
            ?assertError({lawspec, {mailbox, closed}}, lawspec_beam_mailbox:send_remote(Sender, 21)),
            ?assert(lists:any(fun(#{outcome := O}) -> O =:= lost end, lawspec_beam_memory_network:trace(Net)))
        end) end}.

remote_canonical_data_and_malformed_requests_test() ->
    with_network(#{}, fun(_, A, B) ->
        D = <<"(data Job (ctor Job::Idle) (ctor Job::Work (text) (int Int32 _ _))) (ref Job)">>,
        Box = lawspec_beam_mailbox:serve(A, <<"jobs">>, D), Address = lawspec_beam_mailbox:address(Box),
        Sender = lawspec_beam_mailbox:connect(B, Address, D, 1000),
        Value = {ls_data, <<"Job::Work">>, [<<"parcel">>, 42]},
        ok = lawspec_beam_mailbox:send_remote(Sender, Value), ?assertEqual(Value, lawspec_beam_mailbox:receive_value(Box)),
        ?assertMatch({3, _}, lawspec_beam_node:request(B, Address, <<"mail">>, <<255>>, 1000)),
        ?assertMatch({3, _}, lawspec_beam_node:request(B, Address, <<"call">>, <<>>, 1000)),
        ?assertEqual(nothing(), lawspec_beam_mailbox:receive_within(Box, 0)),
        ok = lawspec_beam_node:send(B, Address, <<"mail">>, lawspec_beam_values:encode([<<"ref">>, <<"Job">>], Value,
            element(1, lawspec_beam_values:from_text(D)))),
        ?assertEqual(just(Value), lawspec_beam_mailbox:receive_within(Box, 1000000)),
        ?assert(is_process_alive(Box))
    end).

node_owns_mailbox_and_pending_reader_test() ->
    with_network(#{}, fun(_, A, _) ->
        Box = lawspec_beam_mailbox:serve(A, <<"jobs">>, <<"(text)">>), Parent = self(),
        {Pid, Ref} = spawn_monitor(fun() ->
            ?assertError({lawspec, {mailbox, closed}}, lawspec_beam_mailbox:receive_value(Box)), Parent ! ended
        end),
        waiting(Box), ok = lawspec_beam_node:stop(A), ?assertNot(is_process_alive(Box)),
        receive ended -> ok after 1000 -> error(stranded_reader) end,
        receive {'DOWN', Ref, process, Pid, normal} -> ok end
    end).

partition_times_out_without_admitting_a_message_test() ->
    with_network(#{}, fun(Net, A, B) ->
        Box = lawspec_beam_mailbox:serve(A, <<"jobs">>, <<"(text)">>),
        Sender = lawspec_beam_mailbox:connect(B, lawspec_beam_mailbox:address(Box), <<"(text)">>, 20),
        ok = lawspec_beam_memory_network:partition(Net, [[<<"a">>], [<<"b">>]]),
        ?assertException(error, {lawspec, {network, _}}, lawspec_beam_mailbox:send_remote(Sender, <<"lost">>)),
        ok = lawspec_beam_memory_network:heal(Net),
        ?assertEqual(nothing(), lawspec_beam_mailbox:receive_within(Box, 0)),
        ok = lawspec_beam_mailbox:send_remote(Sender, <<"next">>),
        ?assertEqual(<<"next">>, lawspec_beam_mailbox:receive_value(Box))
    end).

nothing() -> {ls_data, <<"Maybe::Nothing">>, []}.
just(Value) -> {ls_data, <<"Maybe::Just">>, [Value]}.
waiting(Box) -> waiting(Box, erlang:monotonic_time(millisecond) + 1000).
waiting(Box, Deadline) ->
    case maps:get(reader, sys:get_state(Box)) of
        none ->
            ?assert(erlang:monotonic_time(millisecond) < Deadline),
            receive after 1 -> waiting(Box, Deadline) end;
        Reader -> Reader
    end.
with_network(Faults, Body) ->
    lawspec_beam_memory_network:with_network(Faults, fun(Net) ->
        {ok, A} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, <<"a">>)),
        {ok, B} = lawspec_beam_node:start(lawspec_beam_memory_network:insecure_transport_for_tests(Net, <<"b">>)),
        try Body(Net, A, B) after lawspec_beam_node:stop(B), lawspec_beam_node:stop(A) end
    end).
