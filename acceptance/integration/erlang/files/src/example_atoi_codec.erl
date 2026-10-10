%% ref:DEC-acceptance-with-mutants
-module(example_atoi_codec).
-export([itoa/1, atoi/1]).
itoa(Value) -> integer_to_binary(Value).
atoi(Value) -> binary_to_integer(Value).
