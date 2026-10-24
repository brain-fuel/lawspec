%% User-owned LawSpec adapter. Implement these functions.
-module(example_abilities).
-export([charge/2, gateway_handler/0]).

-spec charge(lawspec_abilities_example_abilities:gateway(), -2147483648..2147483647) -> boolean().

charge(_GatewayHandler, _Int32) -> erlang:error({not_implemented, <<"example.abilities::charge">>}).

-spec gateway_handler() -> lawspec_abilities_example_abilities:gateway().

gateway_handler() ->
    #{
        authorize => fun(_Int32) ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.abilities::ability::Gateway.authorize">>
                }
            )
        end,
        capture => fun(_Int32) ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.abilities::ability::Gateway.capture">>
                }
            )
        end,
        fee => fun() ->
            erlang:error(
                {not_implemented, <<"Not implemented: example.abilities::ability::Gateway.fee">>}
            )
        end
    }.
