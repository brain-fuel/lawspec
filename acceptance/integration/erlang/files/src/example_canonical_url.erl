%% ref:DEC-acceptance-with-mutants
-module(example_canonical_url).
-export([canonicalize/1]).
canonicalize(<<>>) -> <<>>;
canonicalize(Value) ->
    case binary:last(Value) of
        $/ -> canonicalize(binary:part(Value, 0, byte_size(Value) - 1));
        _ -> Value
    end.
