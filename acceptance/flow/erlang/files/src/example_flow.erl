%% ref:DEC-acceptance-with-mutants
-module(example_flow).
-export([push/2, pop/1, peek/1]).
push(Value, Stack) -> {push_flow, {stack_push, {record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be, Stack, Value}}}.
pop({stack_push, {record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be, Rest, Top}}) -> {pop_flow, Top, Rest}.
peek({stack_push, {record6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be, _, Top}} = Stack) -> {peek_flow, Top, Stack}.
