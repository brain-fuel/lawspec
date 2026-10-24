%% User-owned LawSpec adapter. Implement these functions.
-module(example_gadt).
-export([eval_number/1, eval_truth/1, eval_pair/1, fold/1, describe/1]).

-spec eval_number(lawspec_data:expr(integer())) -> integer().

eval_number(_ExprInteger) -> erlang:error({not_implemented, <<"example.gadt::evalNumber">>}).

-spec eval_truth(lawspec_data:expr(boolean())) -> boolean().

eval_truth(_ExprBool) -> erlang:error({not_implemented, <<"example.gadt::evalTruth">>}).

-spec eval_pair(
    lawspec_data:expr(lawspec_data:pair(integer(), boolean()))
) -> lawspec_data:pair(integer(), boolean()).

eval_pair(_ExprPairIntegerBool) -> erlang:error({not_implemented, <<"example.gadt::evalPair">>}).

-spec fold(lawspec_data:expr(integer())) -> lawspec_data:expr(integer()).

fold(_ExprInteger) -> erlang:error({not_implemented, <<"example.gadt::fold">>}).

-spec describe(lawspec_data:shown()) -> binary().

describe(_Shown) -> erlang:error({not_implemented, <<"example.gadt::describe">>}).
