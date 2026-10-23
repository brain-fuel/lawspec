%% User-owned LawSpec adapter. Implement these functions.
-module(example_async_workflows).
-export([first/2, second/2, public_probe/1, coordination_handler/0]).

-spec first(
    lawspec_abilities_example_async_workflows:coordination(),
    -128..127
) -> {left, binary()} | {right, -128..127}.

first(_CoordinationHandler, _Int8) ->
    erlang:error({not_implemented, <<"example.asyncWorkflows::first">>}).

-spec second(
    lawspec_abilities_example_async_workflows:coordination(),
    -128..127
) -> {left, binary()} | {right, -128..127}.

second(_CoordinationHandler, _Int8) ->
    erlang:error({not_implemented, <<"example.asyncWorkflows::second">>}).

-spec public_probe(ok) -> boolean().

public_probe(_Unit) -> erlang:error({not_implemented, <<"example.asyncWorkflows::publicProbe">>}).

-spec coordination_handler() -> lawspec_abilities_example_async_workflows:coordination().

coordination_handler() ->
    #{
        meet => fun(_Int32) ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.asyncWorkflows::ability::Coordination.meet">>
                }
            )
        end,
        finish => fun(_Int32) ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.asyncWorkflows::ability::Coordination.finish">>
                }
            )
        end
    }.
