%% ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
-module(example_models).
-export([empty/1, push/2, pop/1, peek/1, new_counter/1, increment/1, decrement/1, read/1]).

empty(ok) -> stack_empty.
push(N, S) -> {push_flow, {stack_push, {recordd055baeeed41ba47fc1e56412cb39424d62fb8f1a3afa343166abc5bf09d2949, S, N}}}.
pop({stack_push, {recordd055baeeed41ba47fc1e56412cb39424d62fb8f1a3afa343166abc5bf09d2949, S, N}}) -> {pop_flow, N, S}.
peek({stack_push, {recordd055baeeed41ba47fc1e56412cb39424d62fb8f1a3afa343166abc5bf09d2949, _, N}} = S) -> {peek_flow, N, S}.
new_counter(ok) -> {counter, beam_model_counter:new()}.
increment({counter, Id}) -> beam_model_counter:increment(Id).
decrement({counter, Id}) -> beam_model_counter:decrement(Id).
read({counter, Id}) -> beam_model_counter:read(Id).
