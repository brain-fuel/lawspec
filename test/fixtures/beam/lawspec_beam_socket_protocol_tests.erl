%% ref:DEC-tests-cite-requirements ref:DEC-distribution-canonical-wire
-module(lawspec_beam_socket_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

addresses_validate_scheme_authority_and_ports_test() ->
    P = lawspec_beam_socket_protocol,
    ?assertEqual({ok, "localhost", 4567}, P:endpoint(tcp, <<"tcp://localhost:4567">>)),
    ?assertEqual({ok, "::1", 80}, P:endpoint(http, P:address(http, <<"::1">>, 80))),
    lists:foreach(fun(Address) -> ?assertEqual({error, invalid_peer_address}, P:endpoint(tcp, Address)) end,
        [<<"http://host:1">>, <<"tcp://host">>, <<"tcp://host:0">>, <<"tcp://host:65536">>,
         <<"tcp://user@host:1">>, <<"tcp://host:1/">>, <<"tcp://host:1?key=value">>,
         <<"tcp://host:1#fragment">>, <<"tcp://host:1\r\nX-Header: value">>,
         <<"tcp://host:bad">>, <<"tcp://:1">>, <<"tcp://ho%73t:1">>, <<"tcp://ho st:1">>, <<255>>]),
    ?assertNot(P:host(<<"[::1]">>)), ?assertNot(P:host(<<>>)).

request_roundtrip_and_each_fragment_boundary_test() ->
    Body = <<0, 255, "LS\r\n\r\n", 1, 2, 3>>,
    Request = iolist_to_binary(lawspec_beam_socket_protocol:request(<<"http://[::1]:4567">>, Body)),
    {Position, 4} = binary:match(Request, <<"\r\n\r\n">>), End = Position + 4,
    lists:foreach(fun(Size) ->
        <<Prefix:Size/binary, Suffix/binary>> = Request,
        case Size < End of
            true -> ?assertEqual(more, lawspec_beam_socket_protocol:header(Prefix, 1024));
            false -> ?assertEqual({ok, byte_size(Body), binary:part(Prefix, End, Size - End)},
                lawspec_beam_socket_protocol:header(Prefix, 1024))
        end,
        ?assertEqual({ok, byte_size(Body), Body}, lawspec_beam_socket_protocol:header(<<Prefix/binary, Suffix/binary>>, 1024))
    end, lists:seq(0, byte_size(Request))),
    ?assertEqual({ok, 0, <<>>}, parse(<<"content-length: 0\r\n">>)).

ambiguous_and_invalid_framing_is_rejected_test() ->
    lists:foreach(fun(Headers) -> ?assertEqual({error, 400}, parse(Headers)) end,
        [<<"Content-Length: 1\r\ncontent-length: 1\r\n">>, <<"Transfer-Encoding: chunked\r\nContent-Length: 1\r\n">>,
         <<"Content-Length: -1\r\n">>, <<"Content-Length: +1\r\n">>, <<"Content-Length: 1x\r\n">>,
         <<"Content-Length: 1,1\r\n">>, <<"Content-Length: 9999999999999999999999\r\n">>, <<"Content-Length:\r\n">>,
         <<"invalid header\r\n">>]),
    ?assertEqual({error, 411}, parse(<<"Host: localhost\r\n">>)),
    ?assertEqual({error, 413}, parse(<<"Content-Length: 1025\r\n">>)),
    ?assertEqual({error, 417}, parse(<<"Content-Length: 1\r\nExpect: 100-continue\r\n">>)).

header_limit_excludes_body_and_rejects_too_many_fields_test() ->
    Request = iolist_to_binary(lawspec_beam_socket_protocol:request(<<"http://host:1">>, binary:copy(<<1>>, 20000))),
    ?assertMatch({ok, 20000, _}, lawspec_beam_socket_protocol:header(Request, 30000)),
    ?assertEqual({error, 431}, parse(<<"X-Large: ", (binary:copy(<<"x">>, 16384))/binary, "\r\n">>)),
    ?assertEqual({error, 400}, parse(<<(binary:copy(<<"X: a\r\n">>, 101))/binary, "Content-Length: 0\r\n">>)),
    ?assertEqual({error, 431}, lawspec_beam_socket_protocol:header(binary:copy(<<"x">>, 16384), 100)).

path_method_and_reply_test() ->
    P = lawspec_beam_socket_protocol,
    ?assertEqual({error, 404}, P:header(<<"POST /other HTTP/1.1\r\nContent-Length: 0\r\n\r\n">>, 100)),
    ?assertEqual({error, 405}, P:header(<<"GET /lawspec HTTP/1.1\r\n\r\n">>, 100)),
    ?assertEqual({error, 400}, P:header(<<"invalid\r\n\r\n">>, 100)),
    Response = P:response(204),
    lists:foreach(fun(Size) ->
        ?assertEqual(more, P:reply(binary:part(Response, 0, Size)))
    end, lists:seq(0, byte_size(Response) - 1)),
    ?assertEqual(ok, P:reply(Response)),
    lists:foreach(fun(Code) -> ?assertEqual({error, invalid_http_response}, P:reply(P:response(Code))) end,
        [400,404,405,411,413,417,431]).

parse(Headers) -> lawspec_beam_socket_protocol:header(<<"POST /lawspec HTTP/1.1\r\n", Headers/binary, "\r\n">>, 1024).

arbitrary_bytes_cannot_escape_the_parsers_test() ->
    P = lawspec_beam_socket_protocol,
    lists:foreach(fun(I) ->
        Bytes = crypto:hash(sha3_256, <<I:32/unsigned>>),
        ?assertEqual({error, invalid_peer_address}, P:endpoint(tcp, Bytes)),
        ?assertMatch({error, _}, P:header(<<Bytes/binary, "\r\n\r\n">>, 1024)),
        ?assertEqual({error, invalid_http_response}, P:reply(<<Bytes/binary, "\r\n\r\n">>))
    end, lists:seq(1, 2000)).
