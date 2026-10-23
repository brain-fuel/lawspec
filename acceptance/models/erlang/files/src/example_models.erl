%% ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
-module(example_models).
-export([empty/1, push/2, pop/1, peek/1, new_counter/1, increment/1, decrement/1, read/1]).

empty(ok) -> stack_empty.
push(N, S) -> {push_flow, {stack_push, {push_details, S, N}}}.
pop({stack_push, {push_details, S, N}}) -> {pop_flow, N, S}.
peek({stack_push, {push_details, _, N}} = S) -> {peek_flow, N, S}.
new_counter(ok) -> {counter, beam_model_counter:new()}.
increment({counter, Id}) -> beam_model_counter:increment(Id).
decrement({counter, Id}) -> beam_model_counter:decrement(Id).
read({counter, Id}) -> beam_model_counter:read(Id).
