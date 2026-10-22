/** <module> Native account handlers exercised by generated actors and supervisors.
ref:DEC-prolog-janus
*/
:- module(lawspec_cc7a7fd02ba9ed31, [ls_openAccount/2, ls_deposit/3,
    ls_withdrawAll/2, ls_balance/2, ls_close/2, ls_reopen/2,
    ls_depositTwice/2, ls_survivesCrash/2]).
:- use_module(library(janus)).

ls_openAccount(_, value('example.actors::type::Account::Account', [0])).
ls_deposit(value(_, [Before]), Amount,
        value('lawspec.collections::type::Pair::Pair', [After, value('example.actors::type::Account::Account', [After])])) :-
    After is Before+Amount.
ls_withdrawAll(value(_, [Before]),
    value('lawspec.collections::type::Pair::Pair', [Before, value('example.actors::type::Account::Account', [0])])).
ls_balance(Account, value('lawspec.collections::type::Pair::Pair', [Balance, Account])) :- Account = value(_, [Balance]).
ls_close(_, value('example.actors::type::Account::Account', [0])).
ls_reopen(value(_, [Balance]), value('example.actors::type::Account::Account', [Balance])).

ls_depositTwice(Amount, Total) :-
    setup_call_cleanup(py_call(lawspec_actors:'AccountActor':start(), Account),
        deposits(Account, Amount, Total), py_call(Account:stop())).
deposits(Account, Amount, Total) :-
    py_call(builtins:getattr(Account, deposit), Deposit),
    py_call(lawspec_runtime:spawn(Deposit, Amount), First),
    py_call(lawspec_runtime:spawn(Deposit, Amount), Second),
    py_call(First:join(), _), py_call(Second:join(), _), py_call(Account:balance(), Total).

ls_survivesCrash(Amount, Total) :-
    setup_call_cleanup(py_call(lawspec_actors:'BankSupervisor':start(), Bank),
        crash_and_read(Bank, Amount, Total), py_call(Bank:stop())).
crash_and_read(Bank, Amount, Total) :-
    py_call(Bank:account, Account), py_call(Account:deposit(Amount), _),
    py_call(Account:crash()), py_call(Account:balance(), Total).
