%% User-owned LawSpec adapter. Implement these functions.
-module(example_builtins).
-export([elapsed/2, token/2, listening/2, charge/2]).

-spec elapsed(
    lawspec_abilities_lawspec_time:clock(),
    -2147483648..2147483647
) -> lawspec_data:duration().

elapsed(_ClockHandler, _Int32) -> erlang:error({not_implemented, <<"example.builtins::elapsed">>}).

-spec token(
    lawspec_abilities_lawspec_randomness:secure_random(),
    -2147483648..2147483647
) -> binary().

token(_SecureRandomHandler, _Int32) ->
    erlang:error({not_implemented, <<"example.builtins::token">>}).

-spec listening(lawspec_abilities_lawspec_host:ports(), -2147483648..2147483647) -> boolean().

listening(_PortsHandler, _Int32) ->
    erlang:error({not_implemented, <<"example.builtins::listening">>}).

-spec charge(lawspec_abilities_lawspec_logging:log(), -2147483648..2147483647) -> boolean().

charge(_LogHandler, _Int32) -> erlang:error({not_implemented, <<"example.builtins::charge">>}).
