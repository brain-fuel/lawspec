%% User-owned LawSpec adapter. Implement these functions.
-module(example_abilities).
-export([charge/2, gateway_handler/0]).

-spec charge(lawspec_abilities_example_abilities:gateway(), -2147483648..2147483647) -> boolean().

charge(_Handler0, _Argument0) ->
    erlang:error({not_implemented, <<"example.abilities::charge"/utf8>>}).

-spec gateway_handler() -> lawspec_abilities_example_abilities:gateway().

gateway_handler() ->
    #{
        authorize => fun(_argument0) ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.abilities::ability::Gateway.authorize"/utf8>>
                }
            )
        end,
        capture => fun(_argument0) ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.abilities::ability::Gateway.capture"/utf8>>
                }
            )
        end,
        fee => fun() ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.abilities::ability::Gateway.fee"/utf8>>
                }
            )
        end
    }.
