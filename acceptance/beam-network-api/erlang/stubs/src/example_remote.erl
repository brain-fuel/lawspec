%% User-owned LawSpec adapter. Implement these functions.
-module(example_remote).
-export([native_probe/1, offset_handler/0]).

-spec native_probe(ok) -> boolean().

native_probe(_Argument0) -> erlang:error({not_implemented, <<"example.remote::nativeProbe"/utf8>>}).

-spec offset_handler() -> lawspec_abilities_example_remote:offset().

offset_handler() ->
    #{
        shift => fun(_argument0) ->
            erlang:error(
                {not_implemented, <<"Not implemented: example.remote::ability::Offset.shift"/utf8>>}
            )
        end
    }.
