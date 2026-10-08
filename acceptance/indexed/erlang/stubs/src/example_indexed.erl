%% User-owned LawSpec adapter. Implement these functions.
-module(example_indexed).
-export([replicate/2, append/2, zip/2, flatten/1]).

-spec replicate(integer(), -128..127) -> lawspec_data:vec(-128..127).

replicate(_Argument0, _Argument1) ->
    erlang:error({not_implemented, <<"example.indexed::replicate"/utf8>>}).

-spec append(lawspec_data:vec(-128..127), lawspec_data:vec(-128..127)) ->
    lawspec_data:vec(-128..127).

append(_Argument0, _Argument1) ->
    erlang:error({not_implemented, <<"example.indexed::append"/utf8>>}).

-spec zip(lawspec_data:vec(-128..127), lawspec_data:vec(boolean())) -> lawspec_data:vec(boolean()).

zip(_Argument0, _Argument1) -> erlang:error({not_implemented, <<"example.indexed::zip"/utf8>>}).

-spec flatten(lawspec_data:tree(-128..127)) -> lawspec_data:vec(-128..127).

flatten(_Argument0) -> erlang:error({not_implemented, <<"example.indexed::flatten"/utf8>>}).
