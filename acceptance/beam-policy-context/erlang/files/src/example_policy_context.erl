%% ref:DEC-acceptance-with-mutants
-module(example_policy_context).
-export([step/1, undo/1, always_fail/1, native_probe/1]).
step(N) ->
    case beam_policy_context_probe:succeeds(N) of true -> {right, N}; false -> {left, <<"retry">>} end.
undo(N) -> beam_policy_context_probe:undo(N).
always_fail(_) -> {left, <<"stopped">>}.
native_probe(ok) -> beam_policy_context_probe:check([
    {<<"fixed">>, fun(N) -> case example_policy_context_definitions:fixed(N) of {right, _} -> true; {left, _} -> false end end},
    {<<"linear">>, fun(N) -> case example_policy_context_definitions:linear(N) of {right, _} -> true; {left, _} -> false end end},
    {<<"fibonacci">>, fun(N) -> case example_policy_context_definitions:fibonacci(N) of {right, _} -> true; {left, _} -> false end end},
    {<<"custom">>, fun(N) -> case example_policy_context_definitions:custom(N) of {right, _} -> true; {left, _} -> false end end},
    {<<"rejected">>, fun(N) -> case example_policy_context_definitions:rejected(N) of {right, _} -> true; {left, _} -> false end end},
    {<<"cached">>, fun(N) -> case example_policy_context_definitions:cached(N) of {right, _} -> true; {left, _} -> false end end},
    {<<"broken">>, fun(N) -> case example_policy_context_definitions:broken(N) of {right, _} -> true; {left, _} -> false end end},
    {<<"bounded">>, fun(N) -> case example_policy_context_definitions:bounded(N) of {right, _} -> true; {left, _} -> false end end},
    {<<"waiting">>, fun(N) -> case example_policy_context_definitions:waiting(N) of {right, _} -> true; {left, _} -> false end end},
    {<<"compensated">>, fun(N) -> case example_policy_context_definitions:compensated(N) of {right, _} -> true; {left, _} -> false end end}
]).
