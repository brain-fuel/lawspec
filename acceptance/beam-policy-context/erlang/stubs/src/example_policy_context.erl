%% User-owned LawSpec adapter. Implement these functions.
-module(example_policy_context).
-export([step/1, undo/1, always_fail/1, native_probe/1]).

-spec step(-2147483648..2147483647) -> {left, binary()} | {right, -2147483648..2147483647}.

step(_Int32) -> erlang:error({not_implemented, <<"example.policy_context::step">>}).

-spec undo(-2147483648..2147483647) -> boolean().

undo(_Int32) -> erlang:error({not_implemented, <<"example.policy_context::undo">>}).

-spec always_fail(-2147483648..2147483647) -> {left, binary()} | {right, -2147483648..2147483647}.

always_fail(_Int32) -> erlang:error({not_implemented, <<"example.policy_context::alwaysFail">>}).

-spec native_probe(ok) -> boolean().

native_probe(_Unit) -> erlang:error({not_implemented, <<"example.policy_context::nativeProbe">>}).
