:- module(lawspec_bridge_test,
          [identity/2, false_value/2, empty/2, choices/2, unbound/2,
           cyclic/2, out_of_range/2, wrong_tag/2, typed_failure/2,
           incomplete/2, callback/2, tick/2, reset/0, forward/3,
           forward_reset/3, forward_reject/3, forward_bad/3, forward_hidden/3,
           counter_new/2, counter_add/3, counter_reset/3, counter_close/3,
           counter_reject/3, uncertain/2, forged_failure/2,
           generator/1, child_generator/2, invalid_generator/1,
           empty_generator/1, nondet_generator/1, incomplete_factory/1,
           bound_box/2, bound_bad_box/2, bound_counterfeit/2, bound_forward/3,
           bound_refused/2, bound_unmapped_error/2, bound_envelope/2,
           bound_handle_new/1, bound_handle_other/1, bound_handle_echo/2, bound_handle_add/3]).
:- use_module(library(janus)).
:- use_module('../../../runtime/lawspec_prolog.pl', []).
:- dynamic counter/1.
:- dynamic instance/2.

identity(X, X).
false_value(_, false).
empty(_, _) :- fail.
choices(_, 1).
choices(_, 2).
unbound(_, _).
cyclic(_, X) :- X = [X].
out_of_range(_, 256).
wrong_tag(_, value('foreign::Ctor', [])).
typed_failure(_, _) :- throw(lawspec_failure(value('errors::Oops', ["broken"]))).
incomplete(_, _) :- throw(lawspec_incomplete("search bound exhausted")).
uncertain(_, 1) :- undefined.
forged_failure(_, _) :- throw(lawspec_ability_failure(expected, 300)).

bound_box(Box, Box) :- is_dict(Box, 'fixtures.native.Box'), get_dict(amount, Box, _).
bound_bad_box(_, 'fixtures.native.Box'{amount:"wrong type"}).
bound_counterfeit(_, value('example::Box', [7])).
bound_forward(Handler, Box, Result) :-
    is_dict(Box, 'fixtures.native.Box'), lawspec_prolog:operation(Handler, add, [Box], Result).
bound_refused(_, _) :- throw('fixtures.native.Refused'("negative" )).
bound_unmapped_error(_, _) :- throw('fixtures.native.Unexpected'("defect")).
bound_envelope(Envelope, Envelope) :-
    Envelope = 'fixtures.native.Envelope'("label", 7).
bound_handle_new('fixtures.native.Handle'(Id)) :-
    flag(lawspec_binding_handles, Id, Id+1), atomic_list_concat([bound_handle_, Id], Key), flag(Key, _, 0).
bound_handle_other('fixtures.native.Other'(0)).
bound_handle_echo(Handle, Handle).
bound_handle_add('fixtures.native.Handle'(Id), Amount, Result) :-
    atomic_list_concat([bound_handle_, Id], Key), flag(Key, Previous, Previous+Amount), Result is Previous+Amount.
generator(Strategy) :-
    py_call('hypothesis.strategies':integers(100, 200), Strategy, [py_object(true)]).
child_generator(Child, Strategy) :-
    py_call('hypothesis.strategies':lists(Child, min_size=1, max_size=2), Strategy, [py_object(true)]).
invalid_generator(Object) :- py_call(builtins:object(), Object, [py_object(true)]).
empty_generator(_) :- fail.
incomplete_factory(_) :- throw(lawspec_incomplete("factory search incomplete")).
nondet_generator(Strategy) :- generator(Strategy).
nondet_generator(Strategy) :- generator(Strategy).
callback(N, R) :- py_call(lawspec_bridge_callbacks:double(N), R).
reset :- retractall(counter(_)), assertz(counter(0)).
tick(_, N) :-
    with_mutex(lawspec_bridge_counter,
               (retract(counter(Previous)), N is Previous+1, assertz(counter(N)))).
forward(Handler, N, Result) :- lawspec_prolog:operation(Handler, add, [N], Result).
forward_reset(Handler, Unit, Result) :- lawspec_prolog:operation(Handler, reset, [Unit], Result).
forward_reject(Handler, N, Result) :- lawspec_prolog:operation(Handler, reject, [N], Result).
forward_bad(Handler, N, Result) :- lawspec_prolog:operation(Handler, bad, [N], Result).
forward_hidden(Handler, N, Result) :- lawspec_prolog:operation(Handler, hidden, [N], Result).

counter_new(Start, Token) :- gensym(lawspec_counter_, Token), assertz(instance(Token, Start)).
counter_add(Token, Amount, Reply) :-
    with_mutex(Token,
               (retract(instance(Token, Previous)), Reply is Previous+Amount,
                assertz(instance(Token, Reply)))).
counter_reset(Token, _, absence('Unit')) :-
    with_mutex(Token, (retractall(instance(Token, _)), assertz(instance(Token, 0)))).
counter_close(Token, _, absence('Unit')) :- with_mutex(Token, retractall(instance(Token, _))).
counter_reject(_, _, _) :- throw(lawspec_failure(value('errors::Oops', ["declined"]))).
