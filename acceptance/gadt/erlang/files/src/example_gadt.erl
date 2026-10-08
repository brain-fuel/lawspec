%% User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
-module(example_gadt).
-export([eval_number/1, eval_truth/1, eval_pair/1, fold/1, describe/1]).

eval_number({expr_number, V}) -> V;
eval_number({expr_plus, L, R}) -> eval_number(L) + eval_number(R).
eval_truth({expr_truth, B}) -> B;
eval_truth({expr_same, L, R}) -> eval_number(L) =:= eval_number(R);
eval_truth({expr_negate, X}) -> not eval_truth(X).
eval_pair({expr_both, L, R}) -> {pair, eval_number(L), eval_truth(R)}.
fold(X) -> {expr_number, eval_number(X)}.
describe({shown, _, Witness}) -> Witness.
