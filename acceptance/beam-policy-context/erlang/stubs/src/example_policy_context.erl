%% User-owned LawSpec adapter. Implement these functions.
-module(example_policy_context).
-export([step/1, undo/1, always_fail/1, native_probe/1]).

-spec step(-2147483648..2147483647) -> {left, binary()} | {right, -2147483648..2147483647}.

step(_Argument0) -> erlang:error({not_implemented, <<"example.policy_context::step"/utf8>>}).

-spec undo(-2147483648..2147483647) -> boolean().

undo(_Argument0) -> erlang:error({not_implemented, <<"example.policy_context::undo"/utf8>>}).

-spec always_fail(-2147483648..2147483647) -> {left, binary()} | {right, -2147483648..2147483647}.

always_fail(_Argument0) ->
    erlang:error({not_implemented, <<"example.policy_context::alwaysFail"/utf8>>}).

-spec native_probe(ok) -> boolean().

native_probe(_Argument0) ->
    erlang:error({not_implemented, <<"example.policy_context::nativeProbe"/utf8>>}).
