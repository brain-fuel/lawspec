/** <module> Native indexed stacks and an atomic shared counter.

Counter IDs and updates use SWI's established atomic flags. The reference
model and history checker remain the existing independent Core implementation.
ref:DEC-prolog-janus
*/
:- module(example_models, [ls_empty/2, ls_push/3, ls_pop/2, ls_peek/2,
    ls_newCounter/2, ls_increment/2, ls_decrement/2, ls_read/2]).
:- dynamic counter_created/1.

ls_empty(_, value('example.models::type::Stack::Empty', [])).
ls_push(Top, Rest, value('example.models::type::PushFlow::PushFlow',
    [value('example.models::type::Stack::Push',
        [value('lawspec::structural::record::d055baeeed41ba47fc1e56412cb39424d62fb8f1a3afa343166abc5bf09d2949::Record', [Rest, Top])])])).
ls_pop(value('example.models::type::Stack::Push', [value(_, [Rest, Top])]),
       value('example.models::type::PopFlow::PopFlow', [Top, Rest])).
ls_peek(Stack, value('example.models::type::PeekFlow::PeekFlow', [Top, Stack])) :-
    Stack = value('example.models::type::Stack::Push', [value(_, [_, Top])]).

ls_newCounter(_, value('example.models::type::Counter::Counter', [Id])) :-
    flag(lawspec_fixture_model_ids, Id, Id+1),
    counter_name(Id, Key), flag(Key, _, 0), assertz(counter_created(Id)).
ls_increment(value(_, [Id]), R) :-
    counter_key(Id, Key), flag(Key, Previous, Previous+1), R is Previous+1.
ls_decrement(value(_, [Id]), R) :-
    counter_key(Id, Key), flag(Key, Previous, Previous-1), R is Previous-1.
ls_read(value(_, [Id]), R) :- counter_key(Id, Key), flag(Key, R, R).

counter_name(Id, Key) :- atomic_list_concat([lawspec_fixture_counter_, Id], Key).
counter_key(Id, Key) :-
    ( counter_created(Id) -> counter_name(Id, Key)
    ; throw(error(existence_error(counter, Id), _))
    ).
