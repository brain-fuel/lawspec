%% ref:DEC-acceptance-with-mutants
-module(example_flow).
-export([push/2, pop/1, peek/1]).
push(Value, Stack) -> {push_flow, {stack_push, Value, Stack}}.
pop({stack_push, Top, Rest}) -> {pop_flow, Top, Rest}.
peek({stack_push, Top, _} = Stack) -> {peek_flow, Top, Stack}.
