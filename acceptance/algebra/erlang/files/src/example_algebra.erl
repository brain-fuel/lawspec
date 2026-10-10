%% ref:DEC-acceptance-with-mutants
-module(example_algebra).
-export([add/2, multiply/2, negate_value/1, maximum_value/2,
    subtract_value/2, divide_left/2, divide_right/2]).
add(A, B) -> A + B.
multiply(A, B) -> A * B.
negate_value(A) -> -A.
maximum_value(A, B) -> max(A, B).
subtract_value(A, B) -> A - B.
divide_left(A, B) -> A - B.
divide_right(A, B) -> A + B.
