/** <module> Indexed stack operations with independent native state values.
ref:DEC-prolog-janus
*/
:- module(lawspec_c75e342719764716, [ls_push/3, ls_pop/2, ls_peek/2]).

ls_push(Top, Rest, value('example.flow::type::PushFlow::PushFlow',
    [value('example.flow::type::Stack::Push',
        [value('lawspec::structural::record::6e70c38da816203dd3a94111f83b422c58c2d67a01c3842a3fd23715879f00be::Record', [Rest, Top])])])).

ls_pop(value('example.flow::type::Stack::Push', [value(_, [Rest, Top])]),
       value('example.flow::type::PopFlow::PopFlow', [Top, Rest])).

ls_peek(Stack, value('example.flow::type::PeekFlow::PeekFlow', [Top, Stack])) :-
    Stack = value('example.flow::type::Stack::Push', [value(_, [_, Top])]).
