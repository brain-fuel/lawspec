%% User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
-module(example_gadt).
-export([eval_number/1, eval_truth/1, eval_pair/1, fold/1, describe/1]).

eval_number({expr_number, V}) -> V;
eval_number({expr_plus, {record772b3aa87ecd053fcced573681dbd8344f63903af98f493d5b458b00157f001e, L, R}}) -> eval_number(L) + eval_number(R).
eval_truth({expr_truth, B}) -> B;
eval_truth({expr_same, {record772b3aa87ecd053fcced573681dbd8344f63903af98f493d5b458b00157f001e, L, R}}) -> eval_number(L) =:= eval_number(R);
eval_truth({expr_negate, X}) -> not eval_truth(X).
eval_pair({expr_both, {recorddf69a8df6c38a0adbe741f620a312261d0d3b0973eba2bc27135c83989a8365e, L, R}}) -> {pair, eval_number(L), eval_truth(R)}.
fold(X) -> {expr_number, eval_number(X)}.
describe({shown, _, Witness}) -> Witness.
