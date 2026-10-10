%% @doc Node identity and trust bindings use the shared configuration file.
%% ref:DEC-distribution-canonical-wire
-module(lawspec_beam_network_config).
-export([options/1]).

options(Explicit) ->
    Config = case maps:is_key(identity, Explicit) andalso maps:is_key(trusted, Explicit) of
        true -> #{};
        false -> configured()
    end,
    Merged = maps:merge(Config, Explicit),
    Identity = case maps:find(identity, Merged) of
        error -> lawspec_beam_network_crypto:identity(crypto:strong_rand_bytes(32));
        {ok, Seed} when is_binary(Seed) -> lawspec_beam_network_crypto:identity(Seed);
        {ok, Value} -> _ = lawspec_beam_network_crypto:public(Value), Value
    end,
    Trusted = case maps:get(trusted, Merged, none) of
        none -> none;
        Values when is_list(Values) -> maps:from_list([{fingerprint(V), true} || V <- Values])
    end,
    #{identity => Identity, trusted => Trusted}.
fingerprint(Value) when is_binary(Value), byte_size(Value) =:= 64 ->
    _ = binary:decode_hex(Value), string:lowercase(Value);
fingerprint(_) -> error({lawspec, invalid_trusted_fingerprint}).
configured() ->
    Path = case os:getenv("LAWSPEC_NETWORK_CONF") of
        false -> {ok, Cwd} = file:get_cwd(), locate(Cwd);
        File -> filename:absname(File)
    end,
    case Path of
        none -> #{};
        _ -> case file:read_file(Path) of
            {error, enoent} -> #{};
            {ok, Bytes} -> lists:foldl(fun(Line, Acc) -> entry(Line, filename:dirname(Path), Acc) end,
                #{}, binary:split(Bytes, <<"\n">>, [global]));
            {error, Reason} -> error({lawspec, {network_configuration, Reason}})
        end
    end.
locate(Directory) ->
    Path = filename:join(Directory, "lawspec-network.conf"),
    case filelib:is_regular(Path) of
        true -> Path;
        false -> case filename:dirname(Directory) of Directory -> none; Parent -> locate(Parent) end
    end.
entry(Line, Directory, Acc) ->
    case string:lexemes(string:trim(Line), " \t\r") of
        [Kind | Rest] when Kind =:= <<"identity">>; Kind =:= <<"trusted">> ->
            %% The path is the complete remainder, so spaces are preserved.
            [_ | _] = Rest,
            Name = string:trim(binary:part(string:trim(Line), byte_size(Kind), byte_size(string:trim(Line)) - byte_size(Kind))),
            Path = filename:join(Directory, unicode:characters_to_list(Name)),
            {ok, Text} = file:read_file(Path),
            case Kind of
                <<"identity">> -> Acc#{identity => binary:decode_hex(string:trim(Text))};
                <<"trusted">> -> Acc#{trusted => string:lexemes(Text, " \t\r\n")}
            end;
        _ -> Acc
    end.
