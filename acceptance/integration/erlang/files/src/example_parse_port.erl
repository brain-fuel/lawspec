%% ref:DEC-acceptance-with-mutants
-module(example_parse_port).
-export([valid_port/1, render/1, parse/1]).
valid_port(Value) -> Value >= 1 andalso Value =< 65535.
render(Value) -> true = valid_port(Value), integer_to_binary(Value).
parse(Value) -> binary_to_integer(Value).
