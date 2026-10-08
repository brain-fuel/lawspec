%% @doc A typed mailbox stores logical values. Native conversion and Clock
%% callbacks run in the caller; the queue never executes application code.
%% Closing refuses new sends and lets accepted values drain. A served box
%% belongs to its node; remote sends complete after once-only admission.
%% ref:DEC-actors-otp-supervision ref:DEC-distribution-canonical-wire
-module(lawspec_beam_mailbox).
-behaviour(gen_server).
-export([open/0, with_mailbox/1, stop/1, close/1, send/2, receive_value/1,
    receive_within/2, receive_with_clock/3, serve/3, connect/4, send_remote/2, address/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export_type([mailbox/0, sender/0]).

-opaque mailbox() :: pid().
-opaque sender() :: {lawspec_mailbox_sender, pid(), binary(), map(), list(), pos_integer()}.

open() -> start(none, none).
with_mailbox(Body) ->
    Box = start(self(), none), try Body(Box) after stop(Box) end.
start(Owner, Network) -> {ok, Box} = gen_server:start(?MODULE, {Owner, Network}, []), Box.
stop(Box) ->
    try gen_server:stop(Box, normal, infinity)
    catch exit:noproc -> ok; exit:{noproc, _} -> ok; exit:{normal, _} -> ok end.
close(Box) ->
    try call(Box, close) catch error:{lawspec, {mailbox, closed}} -> ok end.
send(Box, Value) -> call(Box, {send, Value}).
receive_value(Box) -> {value, Value} = call(Box, {'receive', infinity}), Value.

%% Microseconds, matching LawSpec Duration and the native workflow API.
receive_within(Box, Micros) when is_integer(Micros) ->
    maybe_value(call(Box, {'receive', erlang:monotonic_time(microsecond) + max(0, Micros)}));
receive_within(_, _) -> fail(invalid_duration).
maybe_value(timeout) -> {ls_data, <<"Maybe::Nothing">>, []};
maybe_value({value, Value}) -> {ls_data, <<"Maybe::Just">>, [Value]}.

receive_with_clock(Box, Micros, Schema) when is_integer(Micros) ->
    Handler = lawspec_beam_effects:handler(Schema, <<"lawspec.time::ability::Clock">>),
    case real_clock(Handler) of
        true -> receive_within(Box, Micros);
        false -> case call(Box, {'receive', erlang:monotonic_time(microsecond)}) of
            {value, _} = Value -> maybe_value(Value);
            timeout ->
                _ = lawspec_beam_effects:invoke(Handler, Schema, <<"sleep">>,
                    [{ls_data, <<"lawspec.time::type::Duration::Duration">>, [max(0, Micros)]}]),
                maybe_value(timeout)
        end
    end;
receive_with_clock(_, _, _) -> fail(invalid_duration).
real_clock({lawspec_recording, _, Inner}) -> real_clock(Inner);
real_clock(Handler) -> Handler =:= lawspec_beam_defaults:handler(<<"lawspec.time::ability::Clock">>).

serve(Node, Name, Descriptor) ->
    {Table, Type} = lawspec_beam_values:from_text(Descriptor),
    start(none, #{node => Node, name => Name, table => Table, type => Type}).
connect(Node, Address, Descriptor, Timeout) when is_pid(Node), is_binary(Address), is_integer(Timeout), Timeout > 0 ->
    {Table, Type} = lawspec_beam_values:from_text(Descriptor),
    {lawspec_mailbox_sender, Node, Address, Table, Type, Timeout};
connect(_, _, _, _) -> fail(invalid_sender).
send_remote({lawspec_mailbox_sender, Node, Address, Table, Type, Timeout}, Value) ->
    Bytes = lawspec_beam_values:encode(Type, Value, Table),
    case lawspec_beam_node:request(Node, Address, <<"mail">>, Bytes, Timeout) of
        {0, <<>>} -> ok;
        {2, _} -> fail(closed);
        {Status, Body} -> fail({remote, Status, Body})
    end.
address(Box) -> call(Box, address).
call(Box, Request) ->
    Result = try gen_server:call(Box, Request, infinity)
        catch exit:{_, {gen_server, call, [Box, _, infinity]}} -> {error, closed} end,
    case Result of {ok, Value} -> Value; {error, Reason} -> fail(Reason) end.
fail(Reason) -> error({lawspec, {mailbox, Reason}}).

init({Owner, Network}) ->
    Network1 = case Network of
        none -> none;
        #{node := Node, name := Name} -> Network#{address => lawspec_beam_node:register_service(Node, Name),
            monitor => monitor(process, Node)}
    end,
    {ok, #{queue => queue:new(), closed => false, reader => none, network => Network1,
        owner => case Owner of none -> none; _ -> monitor(process, Owner) end}}.
handle_call(close, _, State) -> reply(ok, State#{closed := true});
handle_call({send, _}, _, State = #{closed := true}) -> {reply, {error, closed}, State};
handle_call({send, Value}, _, State) -> reply(ok, enqueue(Value, State));
handle_call(address, _, State = #{network := none}) -> {reply, {error, local_mailbox}, State};
handle_call(address, _, State = #{network := #{address := Address}}) -> {reply, {ok, Address}, State};
handle_call({'receive', Deadline}, From, State0) ->
    State = prune(State0),
    case maps:get(reader, State) of
        none ->
            {Caller, _} = From,
            Reader = #{from => From, caller => Caller, monitor => monitor(process, Caller),
                deadline => Deadline, token => make_ref(), timer => none},
            finish(wake(State#{reader := Reader}));
        _ -> {reply, {error, already_receiving}, State}
    end;
handle_call(_, _, State) -> {reply, {error, invalid_operation}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info({read_timeout, Token}, State = #{reader := #{token := Token} = Reader}) ->
    finish(wake(State#{reader := Reader#{timer := none}}));
handle_info({'DOWN', Ref, process, _, _}, State = #{owner := Ref}) -> {stop, normal, State};
handle_info({'DOWN', Ref, process, _, _}, State = #{network := #{monitor := Ref}}) -> {stop, normal, State};
handle_info({'DOWN', Ref, process, _, _}, State = #{reader := #{monitor := Ref}}) ->
    finish(clear_reader(State));
handle_info({lawspec_frame, Node, Frame}, State = #{network := #{node := Node} = Network}) ->
    {Status, Body, Next} = incoming(Frame, Network, prune(State)),
    case maps:get(id, Frame) of
        0 -> ok;
        Identity -> ok = lawspec_beam_node:reply(Node, maps:get(source, Frame), Identity, Status, Body)
    end,
    finish(wake(Next));
handle_info(_, State) -> {noreply, State}.
terminate(_, State) ->
    _ = answer({error, closed}, State),
    case maps:get(network, State) of
        none -> ok;
        #{node := Node, name := Name} -> try lawspec_beam_node:unregister(Node, Name) catch _:_ -> ok end
    end.

incoming(_, _, State = #{closed := true}) -> {2, <<"the mailbox is closed">>, State};
incoming(#{kind := <<"mail">>, payload := Bytes}, #{table := Table, type := Type}, State) ->
    try lawspec_beam_values:decode(Type, Bytes, Table) of
        Value -> {0, <<>>, enqueue(Value, State)}
    catch error:_ -> {3, <<"not a message of this mailbox">>, State} end;
incoming(_, _, State) -> {3, <<"not a mailbox request">>, State}.

enqueue(Value, State = #{queue := Queue}) -> State#{queue := queue:in(Value, Queue)}.
prune(State = #{reader := none}) -> State;
prune(State = #{reader := #{caller := Caller}}) ->
    case is_process_alive(Caller) of true -> State; false -> clear_reader(State) end.
reply(Value, State) ->
    case finish(wake(prune(State))) of
        {stop, Reason, Next} -> {stop, Reason, {ok, Value}, Next};
        {noreply, Next} -> {reply, {ok, Value}, Next}
    end.
finish(State = #{closed := true, queue := Queue, network := none}) ->
    case queue:is_empty(Queue) of true -> {stop, normal, State}; false -> {noreply, State} end;
finish(State) -> {noreply, State}.
wake(State = #{reader := none}) -> State;
wake(State = #{queue := Queue, closed := Closed, reader := Reader}) ->
    case queue:out(Queue) of
        {{value, Value}, Rest} -> answer({ok, {value, Value}}, State#{queue := Rest});
        {empty, _} when Closed -> answer({error, closed}, State);
        {empty, _} ->
            case maps:get(deadline, Reader) of
                infinity -> State;
                Deadline ->
                    Left = Deadline - erlang:monotonic_time(microsecond),
                    case Left =< 0 of
                        true -> answer({ok, timeout}, State);
                        false -> case maps:get(timer, Reader) of
                            none ->
                                Timer = erlang:send_after(min(16#ffffffff, (Left + 999) div 1000), self(),
                                    {read_timeout, maps:get(token, Reader)}),
                                State#{reader := Reader#{timer := Timer}};
                            _ -> State
                        end
                    end
            end
    end.
answer(_, State = #{reader := none}) -> State;
answer(Result, State = #{reader := #{from := From}}) ->
    gen_server:reply(From, Result), clear_reader(State).
clear_reader(State = #{reader := none}) -> State;
clear_reader(State = #{reader := Reader}) ->
    demonitor(maps:get(monitor, Reader), [flush]),
    case maps:get(timer, Reader) of none -> ok; Timer -> erlang:cancel_timer(Timer), ok end,
    State#{reader := none}.
