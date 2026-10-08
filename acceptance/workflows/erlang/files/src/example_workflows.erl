%% ref:DEC-acceptance-with-mutants
-module(example_workflows).
-export([audit/1, waitlist/1, check_name/1, check_age/1, open_account/1, check_stock/1, check_credit/1]).
audit(_) -> true.
waitlist(signup_error_unavailable) -> {right, {account, <<"waitlist">>, 18, 0}};
waitlist(Error) -> {left, Error}.
check_name({signup, <<>>, _}) -> {left, signup_error_missing_name};
check_name(Signup) -> {right, Signup}.
check_age({signup, _, Age}) when Age < 18 -> {left, <<"too young">>};
check_age(Signup) -> {right, Signup}.
open_account({signup, <<"taken">>, _}) -> {left, signup_error_unavailable};
open_account({signup, Name, Age}) -> {right, {account, Name, Age, 1}}.
check_stock({order, N} = Order) ->
    case N of -1 -> timer:sleep(400); _ -> ok end,
    case N < 0 of true -> {left, <<"no stock">>}; false -> {right, Order} end.
check_credit({order, N} = Order) ->
    case N of -1 -> timer:sleep(250); _ -> ok end,
    case N < 0 of true -> {left, <<"no credit">>}; false -> {right, Order} end.
