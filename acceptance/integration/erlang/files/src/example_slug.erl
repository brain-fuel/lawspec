%% ref:DEC-acceptance-with-mutants
-module(example_slug).
-export([normalize/1, reference_normalize/1]).
normalize(Value) -> binary:replace(Value, <<" ">>, <<"-">>, [global]).
reference_normalize(Value) -> iolist_to_binary(lists:join(<<"-">>, binary:split(Value, <<" ">>, [global]))).
