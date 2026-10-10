%% @doc Transport envelopes contain shared encrypted records. HTTP is one
%% POST /lawspec per connection; replies travel to the peer's own listener.
%% Parsing is independent of sockets so malformed input can be checked whole
%% and at every possible stream boundary.
%% ref:DEC-distribution-canonical-wire
-module(lawspec_beam_socket_protocol).
-export([endpoint/2, address/3, host/1, request/2, response/1, header/2, reply/1]).

endpoint(Kind, Address) when (Kind =:= tcp orelse Kind =:= http), is_binary(Address) ->
    try case uri_string:parse(Address) of
        #{scheme := Scheme, host := Host, port := Port, path := <<>>} = Parts
                when is_integer(Port), Port > 0, Port =< 65535 ->
            true = Scheme =:= atom_to_binary(Kind),
            true = lists:all(fun(K) -> lists:member(K, [scheme, host, port, path]) end, maps:keys(Parts)),
            true = host(Host), {ok, binary_to_list(Host), Port};
        _ -> {error, invalid_peer_address}
    end catch _:_ -> {error, invalid_peer_address} end;
endpoint(_, _) -> {error, invalid_peer_address}.

host(Host) when is_binary(Host), byte_size(Host) > 0, byte_size(Host) =< 253 ->
    case inet:parse_address(binary_to_list(Host)) of
        {ok, _} -> true;
        _ -> re:run(Host, <<"^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$">>, [{capture, none}]) =:= match
    end;
host(_) -> false.
address(Kind, Host, Port) ->
    Name = case binary:match(Host, <<":">>) of nomatch -> Host; _ -> <<"[", Host/binary, "]">> end,
    <<(atom_to_binary(Kind))/binary, "://", Name/binary, ":", (integer_to_binary(Port))/binary>>.

request(Peer, Bytes) ->
    <<"http://", Authority/binary>> = Peer,
    [<<"POST /lawspec HTTP/1.1\r\nHost: ">>, Authority,
     <<"\r\nContent-Type: application/octet-stream\r\nContent-Length: ">>, integer_to_binary(byte_size(Bytes)),
     <<"\r\nConnection: close\r\n\r\n">>, Bytes].
response(Code) ->
    Reason = case Code of
        204 -> <<"No Content">>; 400 -> <<"Bad Request">>; 404 -> <<"Not Found">>;
        405 -> <<"Method Not Allowed">>; 411 -> <<"Length Required">>;
        413 -> <<"Content Too Large">>; 417 -> <<"Expectation Failed">>;
        431 -> <<"Request Header Fields Too Large">>
    end,
    <<"HTTP/1.1 ", (integer_to_binary(Code))/binary, " ", Reason/binary,
        "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n">>.

%% The header limit excludes the body, even when both arrive in one read.
header(Bytes, Maximum) ->
    case head(Bytes) of
        more -> more;
        {error, Code} -> {error, Code};
        {ok, Head, Rest} ->
            case erlang:decode_packet(http_bin, Head, []) of
                {ok, {http_request, 'POST', {abs_path, <<"/lawspec">>}, Version}, Headers}
                        when Version =:= {1, 0}; Version =:= {1, 1} ->
                    case headers(Headers, #{}, 0) of
                        {ok, Fields} -> length(Fields, Rest, Maximum);
                        _ -> {error, 400}
                    end;
                {ok, {http_request, 'POST', _, _}, _} -> {error, 404};
                {ok, {http_request, _, _, _}, _} -> {error, 405};
                _ -> {error, 400}
            end
    end.
reply(Bytes) ->
    case head(Bytes) of
        more -> more;
        {error, _} -> {error, invalid_http_response};
        {ok, Head, _} -> case erlang:decode_packet(http_bin, Head, []) of
            {ok, {http_response, _, 204, _}, Headers} ->
                case headers(Headers, #{}, 0) of {ok, _} -> ok; _ -> {error, invalid_http_response} end;
            _ -> {error, invalid_http_response}
        end
    end.
head(Bytes) ->
    case binary:match(Bytes, <<"\r\n\r\n">>) of
        {Position, 4} when Position + 4 =< 16384 ->
            Size = Position + 4, <<Head:Size/binary, Rest/binary>> = Bytes, {ok, Head, Rest};
        nomatch when byte_size(Bytes) < 16384 -> more;
        _ -> {error, 431}
    end.
headers(Bytes, Fields, Count) when Count =< 100 ->
    case erlang:decode_packet(httph_bin, Bytes, []) of
        {ok, http_eoh, <<>>} -> {ok, Fields};
        {ok, {http_header, _, Key, _, Value}, Rest} when Count < 100 ->
            Name = string:lowercase(case is_atom(Key) of true -> atom_to_binary(Key); false -> Key end),
            %% Ambiguous framing headers are rejected, including equal lengths.
            case maps:is_key(Name, Fields) andalso lists:member(Name, [<<"content-length">>, <<"transfer-encoding">>]) of
                true -> error;
                false -> headers(Rest, Fields#{Name => string:trim(Value)}, Count + 1)
            end;
        _ -> error
    end.
length(Fields, Rest, Maximum) ->
    case {maps:is_key(<<"transfer-encoding">>, Fields), maps:is_key(<<"expect">>, Fields), maps:find(<<"content-length">>, Fields)} of
        {true, _, _} -> {error, 400};
        {_, true, _} -> {error, 417};
        {_, _, error} -> {error, 411};
        {false, false, {ok, Value}} ->
            case byte_size(Value) =< 10 andalso re:run(Value, <<"^[0-9]+$">>, [{capture, none}]) =:= match of
                false -> {error, 400};
                true -> case binary_to_integer(Value) of
                    Size when Size =< Maximum -> {ok, Size, Rest};
                    _ -> {error, 413}
                end
            end
    end.
