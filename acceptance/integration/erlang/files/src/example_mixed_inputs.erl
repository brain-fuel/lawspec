%% ref:DEC-acceptance-with-mutants
-module(example_mixed_inputs).
-export([normalize/1, identity/1]).
normalize(Value) -> binary:replace(Value, <<" ">>, <<"-">>, [global]).
identity(Value) -> Value.
