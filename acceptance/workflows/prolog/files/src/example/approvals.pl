/** <module> Exercise the checked workflow through its public model interface.
ref:DEC-prolog-janus
*/
:- module(example_approvals, [ls_approvedQuickly/2, ls_approvalErrors/2]).
:- use_module(library(janus)).
:- use_module('../lawspec_prolog.pl', []).
:- use_module('workflows.pl', []).

approve(Number, Result) :-
    py_call(lawspec_runtime:'WorkflowRuntime'(), Runtime),
    py_call(Runtime:context(), Symbols, [py_object(true)]),
    lawspec_prolog:model(context(Symbols), 'example.workflows::approve',
        [value('example.workflows::type::Order::Order', [Number])], Result).

ls_approvedQuickly(Number, Quick) :-
    py_call(time:monotonic(), Started),
    approve(Number, _),
    py_call(time:monotonic(), Finished),
    ( Finished-Started < 0.55 -> Quick = true ; Quick = false ).

ls_approvalErrors(Number, Errors) :-
    example_workflows:reset_finished,
    approve(Number, Result),
    ( Result = value('Either::Left', [value(_, [Failures])]) ->
        maplist(failure_error, Failures, Errors)
    ; Errors = []
    ).
failure_error(value(_, [Error]), Error).
