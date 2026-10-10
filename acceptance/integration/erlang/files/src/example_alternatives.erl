%% ref:DEC-acceptance-with-mutants
-module(example_alternatives).
-export([render/1, reference_render/1, clamp/1, reference_clamp/1]).
render(Value) -> integer_to_binary(Value).
reference_render(Value) -> list_to_binary(integer_to_list(Value)).
clamp(Value) -> max(0, Value).
reference_clamp(Value) -> case Value < 0 of true -> 0; false -> Value end.
