%% @doc Owned TCP and HTTP packet listeners. Only the security layer opens
%% these transports. Per-peer writers preserve order without blocking the
%% node on connection or send timeouts. Closing joins every socket worker.
%% ref:DEC-distribution-canonical-wire ref:DEC-async-native-tasks
-module(lawspec_beam_socket_transport).
-behaviour(gen_server).
-export([start/2, send/3, stop/1, address/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, format_status/1]).

-define(MAX_RECORD, 67108864).
-define(IO_TIMEOUT, 5000).
-define(MAX_WORKERS, 512).

start(Options, Receiver) -> gen_server:start(?MODULE, {Options, Receiver}, []).
send(Pid, Peer, Bytes) -> gen_server:call(Pid, {send, Peer, Bytes}, infinity).
address(Pid) -> gen_server:call(Pid, address, infinity).
stop(Pid) -> try gen_server:stop(Pid, normal, infinity)
    catch exit:noproc -> ok; exit:{noproc, _} -> ok end.

init({Options, Receiver}) ->
    process_flag(trap_exit, true),
    case settings(Options) of
        {error, Reason} -> {stop, Reason};
        {ok, Kind, Host, Port, Advertise} ->
            case resolve(Host) of
                {error, Reason} -> {stop, {listen_address, Reason}};
                {ok, IP, Family} ->
                    Packet = case Kind of tcp -> 4; http -> raw end,
                    Opts = [Family, binary, {ip, IP}, {active, false}, {packet, Packet},
                        {packet_size, ?MAX_RECORD}, {reuseaddr, true}, {nodelay, true},
                        {send_timeout, ?IO_TIMEOUT}, {send_timeout_close, true}],
                    case gen_tcp:listen(Port, Opts) of
                        {error, Reason} -> {stop, {listen, Reason}};
                        {ok, Listener} ->
                            {ok, {_, Actual}} = inet:sockname(Listener), Server = self(),
                            Acceptor = spawn_link(fun() -> accept(Server, Listener) end),
                            {ok, #{owner => Receiver, monitor => monitor(process, Receiver), kind => Kind,
                                address => lawspec_beam_socket_protocol:address(Kind, Advertise, Actual),
                                listener => Listener, acceptor => Acceptor, workers => #{}, peers => #{}}}
                    end
            end
    end.
settings(Options) ->
    Kind = maps:get(kind, Options, none), Host = maps:get(host, Options, <<"127.0.0.1">>),
    Port = maps:get(port, Options, 0), Advertise = maps:get(advertise_host, Options, Host),
    case (Kind =:= tcp orelse Kind =:= http) andalso is_integer(Port) andalso Port >= 0 andalso Port =< 65535
            andalso lawspec_beam_socket_protocol:host(Host) andalso lawspec_beam_socket_protocol:host(Advertise) of
        true -> {ok, Kind, Host, Port, Advertise};
        false -> {error, invalid_transport_options}
    end.
resolve(Host) ->
    Name = binary_to_list(Host),
    case inet:parse_address(Name) of
        {ok, IP} when tuple_size(IP) =:= 8 -> {ok, IP, inet6};
        {ok, IP} -> {ok, IP, inet};
        _ -> case inet:getaddr(Name, inet) of
            {ok, IP} -> {ok, IP, inet};
            _ -> case inet:getaddr(Name, inet6) of {ok, IP} -> {ok, IP, inet6}; Error -> Error end
        end
    end.

handle_call(address, _, State) -> {reply, maps:get(address, State), State};
handle_call(reader, {Acceptor, _}, State = #{acceptor := Acceptor, workers := Workers, kind := Kind}) ->
    case map_size(Workers) < ?MAX_WORKERS of
        false -> {reply, {error, busy}, State};
        true ->
            Server = self(),
            Pid = spawn_link(fun() ->
                Ref = monitor(process, Acceptor),
                receive
                    {socket, Socket} -> demonitor(Ref, [flush]), read(Kind, Server, Socket);
                    {'DOWN', Ref, process, _, _} -> ok
                after ?IO_TIMEOUT -> ok end
            end),
            {reply, {ok, Pid}, State#{workers := Workers#{Pid => reader}}}
    end;
handle_call({send, Peer, Bytes}, {Owner, _}, State = #{owner := Owner, kind := Kind}) when is_binary(Bytes) ->
    case {byte_size(Bytes) =< ?MAX_RECORD, lawspec_beam_socket_protocol:endpoint(Kind, Peer)} of
        {false, _} -> {reply, {error, record_too_large}, State};
        {true, {error, Reason}} -> {reply, {error, Reason}, State};
        {true, {ok, Host, Port}} -> enqueue(Peer, Host, Port, Bytes, State)
    end;
handle_call(_, _, State) -> {reply, {error, not_node_owner}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info({packet, Pid, Bytes}, State = #{workers := Workers, owner := Owner}) ->
    case maps:find(Pid, Workers) of
        {ok, reader} -> Owner ! {lawspec_network, self(), unknown, Bytes};
        _ -> ok
    end,
    {noreply, State};
handle_info({sent, Pid, Size}, State = #{workers := Workers, peers := Peers}) ->
    case maps:find(Pid, Workers) of
        {ok, {writer, Peer}} ->
            {Pid, Count, Total} = maps:get(Peer, Peers),
            {noreply, State#{peers := Peers#{Peer := {Pid, Count - 1, Total - Size}}}};
        _ -> {noreply, State}
    end;
handle_info({'DOWN', Ref, process, _, _}, State = #{monitor := Ref}) -> {stop, normal, State};
handle_info({'EXIT', Pid, Reason}, State = #{acceptor := Pid}) -> {stop, {listener_stopped, Reason}, State};
handle_info({'EXIT', Pid, _}, State) -> {noreply, forget(Pid, State)};
handle_info(_, State) -> {noreply, State}.
terminate(_, #{listener := Listener, acceptor := Acceptor, workers := Workers}) ->
    gen_tcp:close(Listener),
    Waiting = [{Pid, monitor(process, Pid)} || Pid <- [Acceptor | maps:keys(Workers)]],
    lists:foreach(fun({Pid, _}) -> unlink(Pid), exit(Pid, kill) end, Waiting),
    lists:foreach(fun({Pid, Ref}) -> receive {'DOWN', Ref, process, Pid, _} -> ok end end, Waiting).
format_status(Status) -> maps:map(fun(log, _) -> []; (_, _) -> redacted end, Status).

enqueue(Peer, Host, Port, Bytes, State = #{peers := Peers, workers := Workers, kind := Kind}) ->
    case maps:find(Peer, Peers) of
        {ok, {Pid, Count, Total}} ->
            case is_process_alive(Pid) of
                false -> enqueue(Peer, Host, Port, Bytes, forget(Pid, State));
                true when Count < 1024, Total + byte_size(Bytes) =< ?MAX_RECORD ->
                    Pid ! {send, Bytes},
                    {reply, ok, State#{peers := Peers#{Peer := {Pid, Count + 1, Total + byte_size(Bytes)}}}};
                true -> {reply, {error, transport_queue_full}, State}
            end;
        error when map_size(Workers) < ?MAX_WORKERS ->
            Server = self(), Pid = spawn_link(fun() -> write(Kind, Server, Peer, Host, Port, none) end),
            enqueue(Peer, Host, Port, Bytes, State#{peers := Peers#{Peer => {Pid, 0, 0}}, workers := Workers#{Pid => {writer, Peer}}});
        error -> {reply, {error, transport_busy}, State}
    end.
forget(Pid, State = #{peers := Peers, workers := Workers}) ->
    case maps:take(Pid, Workers) of
        error -> State;
        {{writer, Peer}, Rest} -> State#{workers := Rest, peers := maps:remove(Peer, Peers)};
        {_, Rest} -> State#{workers := Rest}
    end.

accept(Server, Listener) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            case gen_server:call(Server, reader, infinity) of
                {ok, Reader} -> case gen_tcp:controlling_process(Socket, Reader) of
                    ok -> Reader ! {socket, Socket};
                    _ -> gen_tcp:close(Socket), exit(Reader, kill)
                end;
                _ -> gen_tcp:close(Socket)
            end,
            accept(Server, Listener);
        {error, closed} -> ok;
        {error, Reason} -> exit({accept, Reason})
    end.
read(tcp, Server, Socket) ->
    case gen_tcp:recv(Socket, 0, ?IO_TIMEOUT) of
        {ok, Bytes} -> Server ! {packet, self(), Bytes}, read(tcp, Server, Socket);
        _ -> gen_tcp:close(Socket)
    end;
read(http, Server, Socket) ->
    Deadline = deadline(),
    try read_head(Socket, <<>>, fun(B) -> lawspec_beam_socket_protocol:header(B, ?MAX_RECORD) end, Deadline) of
        {ok, Size, Rest} -> case body(Socket, Size, Rest, Deadline) of
            {ok, Bytes} -> Server ! {packet, self(), Bytes}, gen_tcp:send(Socket, lawspec_beam_socket_protocol:response(204));
            _ -> gen_tcp:send(Socket, lawspec_beam_socket_protocol:response(400))
        end;
        {error, Code} when is_integer(Code) -> gen_tcp:send(Socket, lawspec_beam_socket_protocol:response(Code));
        _ -> ok
    after gen_tcp:close(Socket) end.
read_head(Socket, Acc, Parse, Deadline) ->
    case Parse(Acc) of
        more -> case gen_tcp:recv(Socket, 0, remaining(Deadline)) of
            {ok, Bytes} -> read_head(Socket, <<Acc/binary, Bytes/binary>>, Parse, Deadline);
            Error -> Error
        end;
        Result -> Result
    end.
body(_, Size, Rest, _) when byte_size(Rest) >= Size -> {ok, binary:part(Rest, 0, Size)};
body(Socket, Size, Rest, Deadline) ->
    case gen_tcp:recv(Socket, Size - byte_size(Rest), remaining(Deadline)) of
        {ok, Bytes} -> {ok, <<Rest/binary, Bytes/binary>>};
        Error -> Error
    end.

write(Kind, Server, Peer, Host, Port, Socket) ->
    receive
        {send, Bytes} ->
            Next = case Kind of
                tcp -> tcp_send(Socket, Host, Port, Bytes, 1);
                http -> http_send(Peer, Host, Port, Bytes), none
            end,
            Server ! {sent, self(), byte_size(Bytes)}, write(Kind, Server, Peer, Host, Port, Next)
    after 60000 -> close(Socket) end.
tcp_send(none, Host, Port, Bytes, Attempts) ->
    case connect(Host, Port, 4) of
        {ok, Socket} -> tcp_send(Socket, Host, Port, Bytes, Attempts);
        _ -> none
    end;
tcp_send(Socket, Host, Port, Bytes, Attempts) ->
    case gen_tcp:send(Socket, Bytes) of
        ok -> Socket;
        _ -> gen_tcp:close(Socket), case Attempts of 0 -> none; _ -> tcp_send(none, Host, Port, Bytes, Attempts - 1) end
    end.
http_send(Peer, Host, Port, Bytes) ->
    case connect(Host, Port, raw) of
        {ok, Socket} ->
            try gen_tcp:send(Socket, lawspec_beam_socket_protocol:request(Peer, Bytes)) of
                ok -> read_head(Socket, <<>>, fun lawspec_beam_socket_protocol:reply/1, deadline());
                Error -> Error
            after gen_tcp:close(Socket) end;
        Error -> Error
    end.
connect(Host, Port, Packet) ->
    case resolve(list_to_binary(Host)) of
        {ok, IP, Family} -> gen_tcp:connect(IP, Port, [Family, binary, {active, false}, {packet, Packet},
            {packet_size, ?MAX_RECORD}, {nodelay, true}, {send_timeout, ?IO_TIMEOUT}, {send_timeout_close, true}], ?IO_TIMEOUT);
        Error -> Error
    end.
close(none) -> ok;
close(Socket) -> gen_tcp:close(Socket).
deadline() -> erlang:monotonic_time(millisecond) + ?IO_TIMEOUT.
remaining(Deadline) -> max(0, Deadline - erlang:monotonic_time(millisecond)).
