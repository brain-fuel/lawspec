%% User-owned LawSpec adapter. Implement these functions.
-module(example_indexed).
-export([replicate/2, append/2, zip/2, flatten/1]).

-spec replicate(non_neg_integer(), -128..127) -> lawspec_data:vec(-128..127).

replicate(_N, _X) -> erlang:error({not_implemented, <<"example.indexed::replicate">>}).

-spec append(
    lawspec_data:vec(-128..127),
    lawspec_data:vec(-128..127)
) -> lawspec_data:vec(-128..127).

append(_Xs, _Ys) -> erlang:error({not_implemented, <<"example.indexed::append">>}).

-spec zip(lawspec_data:vec(-128..127), lawspec_data:vec(boolean())) -> lawspec_data:vec(boolean()).

zip(_Xs, _Ys) -> erlang:error({not_implemented, <<"example.indexed::zip">>}).

-spec flatten(lawspec_data:tree(-128..127)) -> lawspec_data:vec(-128..127).

flatten(_Tree) -> erlang:error({not_implemented, <<"example.indexed::flatten">>}).
