%% User-owned LawSpec adapter. Implement these functions.
-module(example_handler_context).
-export([roundtrip/2, async_roundtrip/2, public_probe/1, counter_handler/0, offset_handler/0]).

-spec roundtrip(
    lawspec_abilities_example_handler_context:counter(),
    -2147483648..2147483647
) -> integer().

roundtrip(_CounterHandler, _Int32) ->
    erlang:error({not_implemented, <<"example.handlerContext::roundtrip">>}).

-spec async_roundtrip(
    lawspec_abilities_example_handler_context:counter(),
    -2147483648..2147483647
) -> integer().

async_roundtrip(_CounterHandler, _Int32) ->
    erlang:error({not_implemented, <<"example.handlerContext::asyncRoundtrip">>}).

-spec public_probe(ok) -> boolean().

public_probe(_Unit) -> erlang:error({not_implemented, <<"example.handlerContext::publicProbe">>}).

-spec counter_handler() -> lawspec_abilities_example_handler_context:counter().

counter_handler() ->
    #{
        bump => fun(_Int32) ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.handlerContext::ability::Counter.bump">>
                }
            )
        end,
        current => fun() ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.handlerContext::ability::Counter.current">>
                }
            )
        end
    }.

-spec offset_handler() -> lawspec_abilities_example_handler_context:offset().

offset_handler() ->
    #{
        offset => fun() ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.handlerContext::ability::Offset.offset">>
                }
            )
        end
    }.
