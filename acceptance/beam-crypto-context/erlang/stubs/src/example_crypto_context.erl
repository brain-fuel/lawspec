%% User-owned LawSpec adapter. Implement these functions.
-module(example_crypto_context).
-export([native_probe/1]).

-spec native_probe(ok) -> boolean().

native_probe(_Argument0) ->
    erlang:error({not_implemented, <<"example.crypto_context::nativeProbe"/utf8>>}).
