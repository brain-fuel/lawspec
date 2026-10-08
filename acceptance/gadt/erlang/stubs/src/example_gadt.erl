%% User-owned LawSpec adapter. Implement these functions.
-module(example_gadt).
-export([eval_number/1, eval_truth/1, eval_pair/1, fold/1, describe/1]).

-spec eval_number(lawspec_data:expr(integer())) -> integer().

eval_number(_Argument0) -> erlang:error({not_implemented, <<"example.gadt::evalNumber"/utf8>>}).

-spec eval_truth(lawspec_data:expr(boolean())) -> boolean().

eval_truth(_Argument0) -> erlang:error({not_implemented, <<"example.gadt::evalTruth"/utf8>>}).

-spec eval_pair(lawspec_data:expr(lawspec_data:pair(integer(), boolean()))) ->
    lawspec_data:pair(integer(), boolean()).

eval_pair(_Argument0) -> erlang:error({not_implemented, <<"example.gadt::evalPair"/utf8>>}).

-spec fold(lawspec_data:expr(integer())) -> lawspec_data:expr(integer()).

fold(_Argument0) -> erlang:error({not_implemented, <<"example.gadt::fold"/utf8>>}).

-spec describe(lawspec_data:shown()) -> binary().

describe(_Argument0) -> erlang:error({not_implemented, <<"example.gadt::describe"/utf8>>}).
