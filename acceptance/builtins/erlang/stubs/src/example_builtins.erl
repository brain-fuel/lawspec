%% User-owned LawSpec adapter. Implement these functions.
-module(example_builtins).
-export([elapsed/2, token/2, listening/2, charge/2]).

-spec elapsed(lawspec_abilities_lawspec_time:clock(), -2147483648..2147483647) ->
    lawspec_data:duration().

elapsed(_Handler0, _Argument0) ->
    erlang:error({not_implemented, <<"example.builtins::elapsed"/utf8>>}).

-spec token(lawspec_abilities_lawspec_randomness:secure_random(), -2147483648..2147483647) ->
    binary().

token(_Handler0, _Argument0) -> erlang:error({not_implemented, <<"example.builtins::token"/utf8>>}).

-spec listening(lawspec_abilities_lawspec_host:ports(), -2147483648..2147483647) -> boolean().

listening(_Handler0, _Argument0) ->
    erlang:error({not_implemented, <<"example.builtins::listening"/utf8>>}).

-spec charge(lawspec_abilities_lawspec_logging:log(), -2147483648..2147483647) -> boolean().

charge(_Handler0, _Argument0) ->
    erlang:error({not_implemented, <<"example.builtins::charge"/utf8>>}).
