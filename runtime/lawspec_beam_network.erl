%% @doc One owned security process per node: signed ML-KEM handshakes,
%% address-pinned ML-DSA identities, and authenticated encrypted frames.
%% ref:DEC-distribution-canonical-wire ref:DEC-async-native-tasks
-module(lawspec_beam_network).
-behaviour(gen_server).
-export([start/3, send/3, stop/1, address/1, identity/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

start(Owner, Transport, Options) -> gen_server:start(?MODULE, {Owner, Transport, Options}, []).
send(Layer, Peer, Frame) -> gen_server:call(Layer, {send, Peer, Frame}, infinity).
address(Layer) -> gen_server:call(Layer, address, infinity).
identity(Layer) -> gen_server:call(Layer, identity, infinity).
stop(Layer) -> try gen_server:stop(Layer, normal, infinity)
    catch exit:noproc -> ok; exit:{noproc, _} -> ok end.

init({Owner, Transport, Options}) ->
    %% Resolve keys before registering a transport. A failed constructor has
    %% no listener or address registration to leak.
    try lawspec_beam_network_config:options(Options) of
        #{identity := Identity, trusted := Trusted} ->
            case lawspec_beam_transport:open(Transport, self()) of
                {ok, Connection = #{pid := Pid, address := Address}} ->
                    {ok, #{owner => Owner, owner_monitor => monitor(process, Owner),
                        connection => Connection, transport_monitor => monitor(process, Pid), address => Address,
                        identity => Identity, trusted => Trusted, known => #{}, sessions => #{},
                        outbound => #{}, pending => #{}, welcomes => #{}}};
                {error, Reason} -> {stop, {transport_registration, Reason}}
            end
    catch
        error:{lawspec, ConfigReason} -> {stop, ConfigReason};
        error:undef -> {stop, crypto_bridge_not_available};
        exit:_ -> {stop, transport_closed};
        _:_ -> {stop, invalid_network_configuration}
    end.
handle_call(address, _, State) -> {reply, maps:get(address, State), State};
handle_call(identity, _, State) -> {reply, lawspec_beam_network_crypto:fingerprint(maps:get(identity, State)), State};
handle_call({send, Peer, Frame}, {Caller, _}, State = #{owner := Caller}) ->
    {Result, Next} = outgoing(Peer, Frame, State), {reply, Result, Next};
handle_call(_, _, State) -> {reply, {error, not_node_owner}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info({lawspec_network, Pid, _, Bytes}, State = #{connection := #{pid := Pid}}) ->
    Next = try incoming(lawspec_beam_network_crypto:read(Bytes), Bytes, State)
        catch _:_ -> State end,
    {noreply, Next};
handle_info({retry, Peer, Session}, State = #{pending := Pending}) ->
    case maps:find(Peer, Pending) of
        {ok, P = #{session := Session, deadline := Deadline}} ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> {noreply, State#{pending := maps:remove(Peer, Pending)}};
                false ->
                    _ = wire(Peer, maps:get(hello, P), State),
                    Timer = erlang:send_after(100, self(), {retry, Peer, Session}),
                    {noreply, State#{pending := Pending#{Peer := P#{timer := Timer}}}}
            end;
        _ -> {noreply, State}
    end;
handle_info({'DOWN', Ref, process, _, _}, State = #{owner_monitor := Ref}) -> {stop, normal, State};
handle_info({'DOWN', Ref, process, _, _}, State = #{transport_monitor := Ref}) -> {stop, normal, State};
handle_info(_, State) -> {noreply, State}.
terminate(_, State) ->
    maps:foreach(fun(_, P) -> erlang:cancel_timer(maps:get(timer, P)) end, maps:get(pending, State)),
    lawspec_beam_transport:close(maps:get(connection, State)), ok.
format_status(Status) -> maps:map(fun(log, _) -> []; (_, _) -> redacted end, Status).

outgoing(Peer, Frame, State = #{outbound := Outbound, sessions := Sessions, pending := Pending}) ->
    case maps:find(Peer, Outbound) of
        {ok, Id} -> S = maps:get(Id, Sessions), {sealed(Peer, Frame, Id, S, State), State};
        error -> case maps:find(Peer, Pending) of
            {ok, P = #{count := Count, queue := Queue}} when Count < 4096 ->
                {ok, State#{pending := Pending#{Peer := P#{count := Count + 1, queue := [Frame | Queue]}}}};
            {ok, _} -> {{error, handshake_queue_full}, State};
            error ->
                Session = crypto:strong_rand_bytes(16),
                {Kem, Seed} = lawspec_beam_crypto:mlkem_keypair(crypto:strong_rand_bytes(64)),
                Identity = maps:get(identity, State),
                Body = lawspec_beam_network_crypto:hello(Session, maps:get(address, State), lawspec_beam_network_crypto:public(Identity), Kem),
                Hello = signed(1, <<"lawspec-handshake-v1-hello", Body/binary>>, Body, Identity),
                case wire(Peer, Hello, State) of
                    ok ->
                        Timer = erlang:send_after(100, self(), {retry, Peer, Session}),
                        P = #{session => Session, seed => Seed, body => Body, hello => Hello, count => 1, queue => [Frame],
                            timer => Timer, deadline => erlang:monotonic_time(millisecond) + 5000},
                        {ok, State#{pending := Pending#{Peer => P}}};
                    Error -> {Error, State}
                end
        end
    end.
incoming({1, [Session, Peer, Public, Kem], Body, Signature}, Record, State = #{welcomes := Welcomes, sessions := Sessions}) ->
    true = byte_size(Session) =:= 16, true = byte_size(Kem) =:= 1184,
    valid_peer(Peer),
    case maps:find(Session, Welcomes) of
        {ok, #{hello := Record, welcome := Answer, peer := Peer}} -> _ = wire(Peer, Answer, State), State;
        {ok, _} -> State;
        error ->
            false = maps:is_key(Session, Sessions),
            false = lists:any(fun(P) -> maps:get(session, P) =:= Session end, maps:values(maps:get(pending, State))),
            true = lawspec_beam_network_crypto:verify(Public, <<"lawspec-handshake-v1-hello", Body/binary>>, Signature),
            Known = accept(Peer, Public, State),
            {Ciphertext, Shared} = lawspec_beam_crypto:mlkem_encapsulate(Kem),
            Identity = maps:get(identity, State),
            Welcome = lawspec_beam_network_crypto:welcome(Session, maps:get(address, State), lawspec_beam_network_crypto:public(Identity), Ciphertext, Body),
            Answer = signed(2, <<"lawspec-handshake-v1-welcome", Welcome/binary>>, Welcome, Identity),
            Key = lawspec_beam_network_crypto:key(Shared, Body, Welcome),
            _ = wire(Peer, Answer, State),
            State#{known := Known, welcomes := Welcomes#{Session => #{hello => Record, welcome => Answer, peer => Peer}},
                sessions := Sessions#{Session => #{peer => Peer, key => Key, direction => 1, confirmed => false}}}
    end;
incoming({2, [Session, Peer, Public, Ciphertext, Hash], Body, Signature}, _, State = #{pending := Pending, sessions := Sessions, outbound := Outbound}) ->
    #{session := Session, body := Hello, seed := Seed, timer := Timer, queue := Queue} = maps:get(Peer, Pending),
    true = byte_size(Ciphertext) =:= 1088,
    Hash = lawspec_beam_crypto:sha3_256(Hello),
    true = lawspec_beam_network_crypto:verify(Public, <<"lawspec-handshake-v1-welcome", Body/binary>>, Signature),
    Known = accept(Peer, Public, State),
    Key = lawspec_beam_network_crypto:key(lawspec_beam_crypto:mlkem_decapsulate(Seed, Ciphertext), Hello, Body),
    S = #{peer => Peer, key => Key, direction => 0, confirmed => true},
    erlang:cancel_timer(Timer),
    Next = State#{known := Known, pending := maps:remove(Peer, Pending), sessions := Sessions#{Session => S}, outbound := Outbound#{Peer => Session}},
    lists:foreach(fun(Frame) -> sealed(Peer, Frame, Session, S, Next) end, lists:reverse(Queue)), Next;
incoming({3, Session, Direction, Bytes}, _, State = #{sessions := Sessions, outbound := Outbound}) ->
    S = #{peer := Peer, key := Key, direction := OwnDirection} = maps:get(Session, Sessions),
    true = Direction =:= 1 - OwnDirection,
    {ok, Frame} = lawspec_beam_network_crypto:open(Key, Session, Direction, Bytes),
    maps:get(owner, State) ! {lawspec_secure, self(), Peer, Frame},
    State#{sessions := Sessions#{Session := S#{confirmed := true}}, outbound := case maps:is_key(Peer, Outbound) of
        true -> Outbound; false -> Outbound#{Peer => Session} end}.

valid_peer(Peer) ->
    Peer = unicode:characters_to_binary(Peer),
    {Peer, <<>>} = lawspec_beam_wire:split_address(<<Peer/binary, "/">>), ok.
accept(Peer, Public, #{known := Known, trusted := Trusted}) ->
    Fingerprint = string:lowercase(binary:encode_hex(lawspec_beam_crypto:sha3_256(Public))),
    true = Trusted =:= none orelse maps:is_key(Fingerprint, Trusted),
    Fingerprint = maps:get(Peer, Known, Fingerprint), Known#{Peer => Fingerprint}.
signed(Kind, Message, Body, Identity) ->
    lawspec_beam_network_crypto:record(Kind, Body, lawspec_beam_network_crypto:sign(Identity, Message)).
wire(Peer, Bytes, #{connection := Connection}) -> lawspec_beam_transport:send(Connection, Peer, Bytes).
sealed(Peer, Frame, Session, #{key := Key, direction := Direction}, State) ->
    wire(Peer, lawspec_beam_network_crypto:seal(Key, Session, Direction, Frame), State).
