%% ref:DEC-acceptance-with-mutants
-module(example_currying).
-export([sum_four/4, format/4, reference_format/4, trim/1]).
sum_four(A, B, C, D) -> A + B + C + D.
format(Prefix, Enabled, Port, Suffix) ->
    Number = case Enabled of true -> integer_to_binary(Port); false -> <<>> end,
    <<Prefix/binary, Number/binary, Suffix/binary>>.
reference_format(Prefix, Enabled, Port, Suffix) ->
    iolist_to_binary([Prefix, case Enabled of true -> integer_to_binary(Port); false -> <<>> end, Suffix]).
trim(Text) -> string:trim(Text).
