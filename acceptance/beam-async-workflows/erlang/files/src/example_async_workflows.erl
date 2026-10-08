%% ref:DEC-acceptance-with-mutants
-module(example_async_workflows).
-export([first/2, second/2, coordination_handler/0, public_probe/1]).
first(Coordination, N) ->
    (maps:get(meet, Coordination))(1),
    (maps:get(finish, Coordination))(1),
    case N < 0 of true -> {left, <<"first">>}; false -> {right, N} end.
second(Coordination, N) ->
    (maps:get(meet, Coordination))(2),
    (maps:get(finish, Coordination))(2),
    case N < 0 of true -> {left, <<"second">>}; false -> {right, N} end.
coordination_handler() -> #{meet => fun(_) -> ok end, finish => fun(_) -> ok end}.
public_probe(ok) ->
    beam_async_probe:probe(fun(Meet, Finish) ->
        Coordination = #{meet => Meet, finish => Finish},
        example_async_workflows_definitions:both(Coordination, -1) =:=
            {left, {both_error_both_failures, [
                {both_error_both_first_failed, <<"first">>},
                {both_error_both_second_failed, <<"second">>}]}}
    end, ok) andalso
    beam_async_probe:probe(fun(Meet, Finish) ->
        Coordination = #{meet => Meet, finish => Finish},
        example_async_workflows_definitions:first_failure(Coordination, -1) =:=
            {left, {first_failure_error_first_failure_first_failed, <<"first">>}}
    end, ok).
