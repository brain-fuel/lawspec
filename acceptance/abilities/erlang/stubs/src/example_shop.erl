%% User-owned LawSpec adapter. Implement these functions.
-module(example_shop).
-export([refund/2, log_handler/0, store_int32_handler/0, store_text_handler/0, meter_handler/0]).

-spec refund(lawspec_abilities_example_abilities:gateway(), -2147483648..2147483647) ->
    -2147483648..2147483647.

refund(_Handler0, _Argument0) -> erlang:error({not_implemented, <<"example.shop::refund"/utf8>>}).

-spec log_handler() -> lawspec_abilities_example_shop:log().

log_handler() ->
    #{
        note => fun(_argument0) ->
            erlang:error(
                {not_implemented, <<"Not implemented: example.shop::ability::Log.note"/utf8>>}
            )
        end
    }.

-spec store_int32_handler() -> lawspec_abilities_example_shop:store_int32().

store_int32_handler() ->
    #{
        load => fun() ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.shop::ability::Store(Int32).load"/utf8>>
                }
            )
        end,
        save => fun(_argument0) ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.shop::ability::Store(Int32).save"/utf8>>
                }
            )
        end
    }.

-spec store_text_handler() -> lawspec_abilities_example_shop:store_text().

store_text_handler() ->
    #{
        load => fun() ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.shop::ability::Store(Text).load"/utf8>>
                }
            )
        end,
        save => fun(_argument0) ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.shop::ability::Store(Text).save"/utf8>>
                }
            )
        end
    }.

-spec meter_handler() -> lawspec_abilities_example_shop:meter().

meter_handler() ->
    #{
        reading => fun() ->
            erlang:error(
                {not_implemented, <<"Not implemented: example.shop::ability::Meter.reading"/utf8>>}
            )
        end
    }.
