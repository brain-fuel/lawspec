%% User-owned LawSpec adapter. Implement these functions.
-module(example_workflows).
-export([
    audit/1,
    waitlist/1,
    check_stock/1,
    check_credit/1,
    check_name/1,
    check_age/1,
    open_account/1
]).

-spec audit(lawspec_data:account()) -> boolean().

audit(_Account) -> erlang:error({not_implemented, <<"example.workflows::audit">>}).

-spec waitlist(
    lawspec_data:signup_error()
) -> {left, lawspec_data:signup_error()} | {right, lawspec_data:account()}.

waitlist(_SignupError) -> erlang:error({not_implemented, <<"example.workflows::waitlist">>}).

-spec check_stock(lawspec_data:order()) -> {left, binary()} | {right, lawspec_data:order()}.

check_stock(_Order) -> erlang:error({not_implemented, <<"example.workflows::checkStock">>}).

-spec check_credit(lawspec_data:order()) -> {left, binary()} | {right, lawspec_data:order()}.

check_credit(_Order) -> erlang:error({not_implemented, <<"example.workflows::checkCredit">>}).

-spec check_name(
    lawspec_data:signup()
) -> {left, lawspec_data:signup_error()} | {right, lawspec_data:signup()}.

check_name(_Signup) -> erlang:error({not_implemented, <<"example.workflows::checkName">>}).

-spec check_age(lawspec_data:signup()) -> {left, binary()} | {right, lawspec_data:signup()}.

check_age(_Signup) -> erlang:error({not_implemented, <<"example.workflows::checkAge">>}).

-spec open_account(
    lawspec_data:signup()
) -> {left, lawspec_data:signup_error()} | {right, lawspec_data:account()}.

open_account(_Signup) -> erlang:error({not_implemented, <<"example.workflows::openAccount">>}).
