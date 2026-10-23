%% User-owned LawSpec adapter. Implement these functions.
-module(example_failures).
-export([refund/1, settle/1, gateway_handler/0]).

-spec refund(-2147483648..2147483647) -> -2147483648..2147483647.

refund(_Int32) -> erlang:error({not_implemented, <<"example.failures::refund">>}).

-spec settle(-2147483648..2147483647) -> -2147483648..2147483647.

settle(_Int32) -> erlang:error({not_implemented, <<"example.failures::settle">>}).

-spec gateway_handler() -> lawspec_abilities_example_failures:gateway().

gateway_handler() ->
    #{
        decide => fun(_Int32) ->
            erlang:error(
                {not_implemented, <<"Not implemented: example.failures::ability::Gateway.decide">>}
            )
        end
    }.
