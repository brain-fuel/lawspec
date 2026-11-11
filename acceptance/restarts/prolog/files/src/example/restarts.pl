/** <module> Native tab handlers exercised by generated actors and supervisors.
ref:DEC-prolog-janus
*/
:- module(example_restarts, [ls_openTab/2, ls_add/3, ls_total/2, ls_keepsTotal/2]).
:- use_module(library(janus)).

ls_openTab(_, value('example.restarts::type::Tab::Tab', [0])).
ls_add(value(_, [Before]), Amount,
        value('lawspec.collections::type::Pair::Pair', [After, value('example.restarts::type::Tab::Tab', [After])])) :-
    After is Before+Amount.
ls_total(Tab, value('lawspec.collections::type::Pair::Pair', [Total, Tab])) :- Tab = value(_, [Total]).

ls_keepsTotal(Amount, Total) :-
    setup_call_cleanup(py_call(lawspec_actors:'BarSupervisor':start(), Bar),
        crash_and_read(Bar, Amount, Total), py_call(Bar:stop())).
crash_and_read(Bar, Amount, Total) :-
    py_call(Bar:tab, Tab), py_call(Tab:add(Amount), _),
    py_call(Tab:crash()), py_call(Tab:total(), Total).
