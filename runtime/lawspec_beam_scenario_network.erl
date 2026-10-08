%% @doc Scenario values use the same canonical frames, reliable endpoints
%% and mailbox receipts as native distribution. Only causal metadata stays
%% beside the transport: channel clocks follow sequence order, and mailbox
%% clocks follow the actual source/request identity, even after reordering.
%% ref:DEC-distribution-canonical-wire ref:DEC-stateful-models-linearizability
-module(lawspec_beam_scenario_network).
-export([new/4, close/1, send/5, abandon/2, event/2, stats/1]).

new(Channels, Mailboxes, Wire, Options) ->
    Forms = case Wire of [<<"wire">> | Fs] -> Fs; none when Channels =:= [], map_size(Mailboxes) =:= 0 -> [];
        _ -> error({lawspec, scenario_wire_required}) end,
    Steps = maps:from_list([{N, Ss} || [<<"channel">>, N | Ss] <- Forms]),
    Types = maps:from_list([{N, D} || [<<"mailbox">>, N, D] <- Forms]),
    require(lists:sort(maps:keys(Steps)) =:= lists:sort(Channels), channel_wire_required),
    require(lists:sort(maps:keys(Types)) =:= lists:sort(maps:keys(Mailboxes)), mailbox_wire_required),
    Table = maps:from_list([{unquote(Name), D} || [<<"data">>, Name | _] = D <- Forms]),
    Defaults = #{seed => maps:get(shake, Options, 0) bxor 16#7f4a7c159e3779b9,
        loss => 0.1, duplicate => 0.1, delay => 0.002, record => true},
    {ok, Network} = lawspec_beam_memory_network:start(maps:merge(Defaults, maps:get(faults, Options, #{}))),
    Base = #{network => Network, nodes => [], ends => #{}, endpoints => #{}, boxes => #{}, inboxes => #{},
        table => Table, flights => #{}, pending => #{},
        monitors => #{monitor(process, Network) => Network}, timeout => maps:get(deadline, Options, 5000)},
    S1 = lists:foldl(fun(Name, S) -> add_channel(Name, maps:get(Name, Steps), S) end, Base, Channels),
    lists:foldl(fun(Name, S) -> add_mailbox(Name, maps:get(Name, Types), S) end, S1, lists:sort(maps:keys(Mailboxes))).
unquote({quoted, Name}) -> Name;
unquote(Name) -> Name.
require(true, _) -> ok;
require(false, Reason) -> error({lawspec, {scenario_network, Reason}}).

add_node(State = #{network := Net, nodes := Nodes, monitors := Monitors}) ->
    Name = <<"scenario-", (integer_to_binary(length(Nodes)))/binary>>,
    {ok, Node} = lawspec_beam_node:start_owned(lawspec_beam_memory_network:insecure_transport_for_tests(Net, Name), #{}),
    {Node, State#{nodes := [Node | Nodes], monitors := Monitors#{monitor(process, Node) => Node}}}.
add_channel(Name, Steps, State) ->
    {A, S1} = add_end(Name, 0, Steps, State), {B, S2} = add_end(Name, 1, Steps, S1),
    ok = lawspec_beam_endpoint:connect(B, lawspec_beam_endpoint:address(A)), S2.
add_end(Name, Side, Steps, State) ->
    {Node, S1} = add_node(State),
    {ok, End} = lawspec_beam_endpoint:start(Node, <<"end">>, #{deadline => maps:get(timeout, State)}),
    Sends = [D || [Verb, D] <- Steps, (Verb =:= <<"send">>) =:= (Side =:= 0)],
    Receives = [D || [Verb, D] <- Steps, (Verb =:= <<"send">>) =/= (Side =:= 0)],
    Ticket = lawspec_beam_endpoint:receive_async(End, infinity),
    Destination = {'end', Name, Side}, Ends = maps:get(ends, S1), Endpoints = maps:get(endpoints, S1),
    Monitors = maps:get(monitors, S1),
    Entry = #{endpoint => End, sends => Sends, receives => Receives, clocks => queue:new(), ticket => Ticket},
    {End, S1#{ends := Ends#{Destination => Entry}, endpoints := Endpoints#{End => Destination},
        monitors := Monitors#{monitor(process, End) => End}}}.
add_mailbox(Name, Type, State) ->
    {Owner, S1} = add_node(State), {Sender, S2} = add_node(S1),
    Address = lawspec_beam_node:register_receiver(Owner, <<"mail">>, self()),
    Boxes = maps:get(boxes, S2), Inboxes = maps:get(inboxes, S2),
    S2#{boxes := Boxes#{{mailbox, Name} => #{sender => Sender, address => Address, type => Type}},
        inboxes := Inboxes#{Owner => {mailbox, Name}}}.
close(State) ->
    maps:foreach(fun(_, #{from := From}) -> gen_server:reply(From, {error, network_closed}) end, maps:get(pending, State)),
    lists:foreach(fun lawspec_beam_node:stop/1, maps:get(nodes, State)),
    lawspec_beam_memory_network:stop(maps:get(network, State)).

send(Destination = {'end', Name, Side}, Value, Clock, _, State = #{ends := Ends}) ->
    Entry = maps:get(Destination, Ends),
    [Type | Rest] = maps:get(sends, Entry),
    Bytes = encode(Type, Value, State),
    ok = lawspec_beam_endpoint:send(maps:get(endpoint, Entry), Bytes),
    Other = {'end', Name, 1 - Side}, Peer = maps:get(Other, Ends),
    {ok, State#{ends := Ends#{Destination := Entry#{sends := Rest},
        Other := Peer#{clocks := queue:in({Value, Clock}, maps:get(clocks, Peer))}}}};
send(Box = {mailbox, _}, Value, Clock, From, State = #{boxes := Boxes, flights := Flights, pending := Pending}) ->
    #{sender := Node, address := Address, type := Type} = maps:get(Box, Boxes),
    Bytes = encode(Type, Value, State),
    {Ticket, Identity} = lawspec_beam_node:request_async(Node, Address, <<"mail">>, Bytes, maps:get(timeout, State)),
    Key = {lawspec_beam_node:address(Node), Identity},
    Flight = #{destination => Box, value => Value, clock => Clock},
    {pending, State#{flights := Flights#{Key => Flight}, pending := Pending#{Ticket => #{from => From, key => Key, node => Node}}}}.
abandon(Destination = {'end', _, _}, State) ->
    ok = lawspec_beam_endpoint:abandon(maps:get(endpoint, maps:get(Destination, maps:get(ends, State)))), State;
abandon({mailbox, _}, State) -> State.

event({lawspec_channel, End, Ticket, Result}, State = #{endpoints := Endpoints, ends := Ends}) ->
    case maps:find(End, Endpoints) of
        {ok, Destination} ->
            Entry = maps:get(Destination, Ends),
            case maps:get(ticket, Entry) of Ticket -> channel_event(Destination, Entry, Result, State); _ -> ignore end;
        error -> ignore
    end;
event({lawspec_frame, Node, Frame = #{source := Source, id := Identity, payload := Bytes}}, State = #{inboxes := Inboxes, flights := Flights}) ->
    Key = {Source, Identity},
    case {maps:find(Node, Inboxes), maps:find(Key, Flights)} of
        {{ok, Box}, {ok, #{destination := Box, clock := Clock}}} ->
            <<"mail">> = maps:get(kind, Frame),
            Value = decode(maps:get(type, maps:get(Box, maps:get(boxes, State))), Bytes, State),
            ok = lawspec_beam_node:reply(Node, Source, Identity, 0, <<>>),
            {[{delivered, Box, Value, Clock}], State#{flights := maps:remove(Key, Flights)}};
        {{ok, _}, _} ->
            ok = lawspec_beam_node:reply(Node, Source, Identity, 3, <<"not a scenario mailbox request">>), {[], State};
        _ -> ignore
    end;
event({lawspec_reply, Node, Ticket, Result}, State = #{pending := Pending, flights := Flights}) ->
    case maps:find(Ticket, Pending) of
        {ok, #{node := Node, from := From, key := Key}} ->
            Reply = case Result of {ok, {0, <<>>}} -> ok; _ -> {error, {mailbox_send_failed, Result}} end,
            gen_server:reply(From, Reply),
            %% A timed-out request may never have reached its destination.
            %% Release its in-flight quota and any end it was carrying.
            Lost = case maps:find(Key, Flights) of
                error -> [];
                {ok, #{destination := Box, value := Value}} -> [{lost, Box, Value}]
            end,
            {Lost, State#{pending := maps:remove(Ticket, Pending), flights := maps:remove(Key, Flights)}};
        _ -> ignore
    end;
event({'DOWN', Monitor, process, Pid, Reason}, #{monitors := Monitors}) ->
    case maps:is_key(Monitor, Monitors) of
        true -> error({lawspec, {scenario_network, {service_stopped, Pid, Reason}}});
        false -> ignore
    end;
event(_, _) -> ignore.

channel_event(Destination, Entry, {value, Bytes}, State = #{ends := Ends}) ->
    [Type | Types] = maps:get(receives, Entry),
    {{value, {_, Clock}}, Clocks} = queue:out(maps:get(clocks, Entry)),
    Value = decode(Type, Bytes, State),
    Ticket = lawspec_beam_endpoint:receive_async(maps:get(endpoint, Entry), infinity),
    {[{delivered, Destination, Value, Clock}], State#{ends := Ends#{Destination := Entry#{receives := Types, clocks := Clocks, ticket := Ticket}}}};
channel_event(Destination, Entry, {error, _}, State = #{ends := Ends}) ->
    Lost = [{lost, Destination, Value} || {Value, _} <- queue:to_list(maps:get(clocks, Entry))],
    {Lost ++ [{gone, Destination}], State#{ends := Ends#{Destination := Entry#{clocks := queue:new(), ticket := none}}}}.

encode([<<"end">>], {lawspec_scenario_end, Name, Side}, State) ->
    require(maps:is_key({'end', Name, Side}, maps:get(ends, State)), unknown_delegated_end),
    lawspec_beam_values:encode([<<"text">>], <<Name/binary, "#", (integer_to_binary(Side))/binary>>, #{});
encode(Type, Value, State) -> lawspec_beam_values:encode(Type, Value, maps:get(table, State)).
decode([<<"end">>], Bytes, State) ->
    Address = lawspec_beam_values:decode([<<"text">>], Bytes, #{}),
    [Number | Names] = lists:reverse(binary:split(Address, <<"#">>, [global])),
    Name = iolist_to_binary(lists:join(<<"#">>, lists:reverse(Names))), Side = binary_to_integer(Number),
    require(maps:is_key({'end', Name, Side}, maps:get(ends, State)), unknown_delegated_end),
    {lawspec_scenario_end, Name, Side};
decode(Type, Bytes, State) -> lawspec_beam_values:decode(Type, Bytes, maps:get(table, State)).

stats(State) ->
    Trace = lawspec_beam_memory_network:trace(maps:get(network, State)),
    #{frames => length(Trace), lost => length([lost || #{outcome := lost} <- Trace]),
        duplicated => length([duplicate || #{delay_slots := [_, _]} <- Trace]),
        pending_requests => map_size(maps:get(pending, State))}.
