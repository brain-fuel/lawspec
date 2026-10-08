%% User-owned LawSpec adapter. Implement these functions.
-module(example_async_workflows).
-export([first/2, second/2, public_probe/1, coordination_handler/0]).

-spec first(lawspec_abilities_example_async_workflows:coordination(), -128..127) ->
    {left, binary()} | {right, -128..127}.

first(_Handler0, _Argument0) ->
    erlang:error({not_implemented, <<"example.asyncWorkflows::first"/utf8>>}).

-spec second(lawspec_abilities_example_async_workflows:coordination(), -128..127) ->
    {left, binary()} | {right, -128..127}.

second(_Handler0, _Argument0) ->
    erlang:error({not_implemented, <<"example.asyncWorkflows::second"/utf8>>}).

-spec public_probe(ok) -> boolean().

public_probe(_Argument0) ->
    erlang:error({not_implemented, <<"example.asyncWorkflows::publicProbe"/utf8>>}).

-spec coordination_handler() -> lawspec_abilities_example_async_workflows:coordination().

coordination_handler() ->
    #{
        meet => fun(_argument0) ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.asyncWorkflows::ability::Coordination.meet"/utf8>>
                }
            )
        end,
        finish => fun(_argument0) ->
            erlang:error(
                {
                    not_implemented,
                    <<"Not implemented: example.asyncWorkflows::ability::Coordination.finish"/utf8>>
                }
            )
        end
    }.
