%% ref:DEC-acceptance-with-mutants
-module(example_boolean_flags).
-export([flip_flag/1]).
flip_flag(Value) -> not Value.
