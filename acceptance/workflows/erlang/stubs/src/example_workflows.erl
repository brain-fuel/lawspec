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

audit(_Argument0) -> erlang:error({not_implemented, <<"example.workflows::audit"/utf8>>}).

-spec waitlist(lawspec_data:signup_error()) ->
    {left, lawspec_data:signup_error()} | {right, lawspec_data:account()}.

waitlist(_Argument0) -> erlang:error({not_implemented, <<"example.workflows::waitlist"/utf8>>}).

-spec check_stock(lawspec_data:order()) -> {left, binary()} | {right, lawspec_data:order()}.

check_stock(_Argument0) ->
    erlang:error({not_implemented, <<"example.workflows::checkStock"/utf8>>}).

-spec check_credit(lawspec_data:order()) -> {left, binary()} | {right, lawspec_data:order()}.

check_credit(_Argument0) ->
    erlang:error({not_implemented, <<"example.workflows::checkCredit"/utf8>>}).

-spec check_name(lawspec_data:signup()) ->
    {left, lawspec_data:signup_error()} | {right, lawspec_data:signup()}.

check_name(_Argument0) -> erlang:error({not_implemented, <<"example.workflows::checkName"/utf8>>}).

-spec check_age(lawspec_data:signup()) -> {left, binary()} | {right, lawspec_data:signup()}.

check_age(_Argument0) -> erlang:error({not_implemented, <<"example.workflows::checkAge"/utf8>>}).

-spec open_account(lawspec_data:signup()) ->
    {left, lawspec_data:signup_error()} | {right, lawspec_data:account()}.

open_account(_Argument0) ->
    erlang:error({not_implemented, <<"example.workflows::openAccount"/utf8>>}).
