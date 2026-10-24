%% ref:DEC-acceptance-with-mutants
-module(example_flow).
-export([push/2, pop/1, peek/1]).
push(Value, Stack) -> {push_flow, {stack_push, {push_details, Stack, Value}}}.
pop({stack_push, {push_details, Rest, Top}}) -> {pop_flow, Top, Rest}.
peek({stack_push, {push_details, _, Top}} = Stack) -> {peek_flow, Top, Stack}.
