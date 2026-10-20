/** <module> Native workflow steps, with independently timed concurrent checks.
ref:DEC-prolog-janus
*/
:- module(lawspec_cfb6be83143715a5, [ls_audit/2, ls_waitlist/2,
    ls_checkName/2, ls_checkAge/2, ls_openAccount/2,
    ls_checkStock/2, ls_checkCredit/2, reset_finished/0, finished/1]).
:- dynamic completed/1.

ls_audit(_, true).
ls_waitlist(Error, Result) :-
    ( Error == value('example.workflows::type::SignupError::Unavailable', []) ->
        Result = value('Either::Right',
            [value('example.workflows::type::Account::Account', ["waitlist", 18, 0])])
    ; Result = value('Either::Left', [Error])
    ).
ls_checkName(Signup, Result) :-
    Signup = value(_, [Name, _]), string_length(Name, Length),
    ( Length =:= 0 ->
        Result = value('Either::Left',
            [value('example.workflows::type::SignupError::MissingName', [])])
    ; Result = value('Either::Right', [Signup])
    ).
ls_checkAge(Signup, Result) :-
    Signup = value(_, [_, Age]),
    ( Age < 18 -> Result = value('Either::Left', ["too young"])
    ; Result = value('Either::Right', [Signup])
    ).
ls_openAccount(value(_, [Name, Age]), Result) :-
    ( Name == "taken" ->
        Result = value('Either::Left',
            [value('example.workflows::type::SignupError::Unavailable', [])])
    ; Result = value('Either::Right',
        [value('example.workflows::type::Account::Account', [Name, Age, 1])])
    ).

ls_checkStock(Order, Result) :- checked(Order, 0.4, "no stock", Result).
ls_checkCredit(Order, Result) :- checked(Order, 0.25, "no credit", Result).
checked(Order, Delay, Error, Result) :-
    Order = value(_, [Number]),
    ( Number =:= -1 -> sleep(Delay) ; true ),
    ( Number < 0 ->
        with_mutex(lawspec_fixture_workflow_finished, assertz(completed(Error))),
        Result = value('Either::Left', [Error])
    ; Result = value('Either::Right', [Order])
    ).

reset_finished :-
    with_mutex(lawspec_fixture_workflow_finished, retractall(completed(_))).
finished(Errors) :-
    with_mutex(lawspec_fixture_workflow_finished, findall(Error, completed(Error), Errors)).
