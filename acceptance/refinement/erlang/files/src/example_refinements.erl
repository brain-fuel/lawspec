%% ref:DEC-acceptance-with-mutants
-module(example_refinements).
-export([add/2, successor/1, count/1, preserve/1, positive/1, abstract_echo/1]).
add(A, B) -> A + B.
successor(Value) -> Value + 1.
count(Text) -> length(unicode:characters_to_list(Text)).
preserve(Value) -> Value.
positive(Value) -> Value.
abstract_echo(Value) -> Value.
