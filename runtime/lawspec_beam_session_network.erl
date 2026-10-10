%% @doc Native session payloads use the shared canonical codecs. An unused
%% network end moves with its reliable state; a local end stays behind a
%% node-owned relay. Nested delegation follows the same protocol catalogue.
%% ref:DEC-distribution-canonical-wire ref:DEC-sessions-by-construction
-module(lawspec_beam_session_network).
-export([validate/1, fresh_name/0, encode/2, decode/2, offer/3, take/4]).

validate(#{id := Id, protocols := Protocols}) -> validate(Id, Protocols, []).
validate(Id, Protocols, Seen) ->
    case lists:member(Id, Seen) of
        true -> ok;
        false ->
            Steps = maps:get(Id, Protocols),
            case Steps of [] -> error({lawspec, {session, empty_network_protocol}}); _ -> ok end,
            lists:foreach(fun
                ({_, {session, Other}}) -> validate(Other, Protocols, [Id | Seen]);
                ({_, {value, none}}) -> error({lawspec, {session, non_wire_payload}});
                ({_, {value, Text}}) -> _ = lawspec_beam_values:from_text(Text), ok
            end, Steps)
    end.
fresh_name() -> <<"session-", (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>.
encode({value, Text}, Value) ->
    {Table, Descriptor} = lawspec_beam_values:from_text(Text), lawspec_beam_values:encode(Descriptor, Value, Table);
encode({session, _}, Address) -> lawspec_beam_values:encode([<<"text">>], Address, #{}).
decode({value, Text}, Bytes) ->
    {Table, Descriptor} = lawspec_beam_values:from_text(Text), lawspec_beam_values:decode(Descriptor, Bytes, Table);
decode({session, _}, Bytes) -> lawspec_beam_values:decode([<<"text">>], Bytes, #{}).

offer(Node, End, Expected) ->
    case lawspec_beam_session:network_offer(End, Expected) of
        {address, Address} -> Address;
        {local, Spec} -> relay(Node, End, Spec)
    end.
take(Node, Address, Spec, Custodian) ->
    Moving = binary:match(Address, <<"?take=">>) =/= nomatch,
    Connection = case Moving of true -> none; false -> Address end,
    %% The receiver always acquires the first end, even when a relay is its
    %% peer. Custody remains with the receiving session until its caller
    %% claims the result, so a killed reader cannot leak the acquired end.
    End = lawspec_beam_session:network_start(Spec, Node, fresh_name(), 0, Connection, Custodian),
    try
        case Moving of
            true -> ok = lawspec_beam_endpoint:take(lawspec_beam_session:network_endpoint(End), Address);
            false -> ok
        end,
        End
    catch Class:Reason:Stack ->
        try lawspec_beam_session:abandon(End) catch _:_ -> ok end,
        erlang:raise(Class, Reason, Stack)
    end.

relay(Node, End, Spec = #{id := Id, protocols := Protocols}) ->
    validate(Spec),
    Remote = lawspec_beam_session:network_start(Spec, Node, fresh_name(), 1, none, none),
    Address = lawspec_beam_session:address(Remote),
    Creator = self(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        Ready = monitor(process, Creator),
        receive
            {start, Local, Network} ->
                demonitor(Ready, [flush]),
                lawspec_beam_session:with_owned([Local, Network], fun() ->
                    pump(Local, Network, maps:get(Id, Protocols))
                end);
            {'DOWN', Ready, process, Creator, Reason} -> exit({relay_setup_failed, Reason})
        end
    end),
    try
        ok = lawspec_beam_node:adopt_service(Node, Worker),
        MovedRemote = lawspec_beam_session:transfer_to_task(Remote, Worker),
        Local = lawspec_beam_session:transfer_to_relay(End, Id, Worker),
        Worker ! {start, Local, MovedRemote}, demonitor(Monitor, [flush]), Address
    catch Class:Reason:Stack ->
        exit(Worker, kill), receive {'DOWN', Monitor, process, Worker, _} -> ok end,
        try lawspec_beam_session:abandon(Remote) catch _:_ -> ok end,
        erlang:raise(Class, Reason, Stack)
    end.
pump(_, _, []) -> ok;
pump(Local, Remote, [{Direction, Part} | Rest]) ->
    {NextLocal, NextRemote} = case {Direction, Part} of
        {send, {value, _}} ->
            {Value, R} = lawspec_beam_session:receive_value(Remote), {lawspec_beam_session:send(Local, Value), R};
        {'receive', {value, _}} ->
            {Value, L} = lawspec_beam_session:receive_value(Local), {L, lawspec_beam_session:send(Remote, Value)};
        {send, {session, _}} ->
            {Value, R} = lawspec_beam_session:receive_end(Remote), {lawspec_beam_session:send_end(Local, Value), R};
        {'receive', {session, _}} ->
            {Value, L} = lawspec_beam_session:receive_end(Local), {L, lawspec_beam_session:send_end(Remote, Value)}
    end,
    pump(NextLocal, NextRemote, Rest).
