/** <module> Native resource state, files, sockets and environment restoration.

Store limits detect missing release, and the pool's one-acquisition budget
checks the shared per-unit lifetime. Core owns acquisition/reset/release order.
ref:DEC-prolog-janus
*/
:- module(lawspec_7a59540223a56e91, [ls_openStore/2, ls_closeStore/2, ls_clearStore/2,
    ls_put/4, ls_get/3, ls_isOpen/2, ls_size/2, ls_writeNote/3, ls_readNote/2,
    ls_canListen/2, ls_setGreeting/2, ls_greeting/2, ls_openPool/2,
    ls_drainPool/2, ls_closePool/2, ls_fill/3, ls_level/2]).
:- use_module(library(janus)).
:- use_module(library(socket)).

ls_openStore(_, opaque(State)) :-
    flag(lawspec_fixture_resource_stores, Count, Count+1),
    ( Count >= 3 -> throw(error(resource_error(unreleased_stores), _)) ; true ),
    py_call(builtins:dict(items=eval(builtins:dict()), open= @(true)), State, [py_object(true)]).

ls_closeStore(Handle, absence('Unit')) :-
    state(Handle, State), py_call(State:get(open), Open),
    ( Open == @(true) ->
        py_call(State:'__setitem__'(open, @(false))),
        flag(lawspec_fixture_resource_stores, Count, Count-1)
    ; true
    ).

ls_clearStore(Handle, absence('Unit')) :-
    state(Handle, State), items(State, Items), py_call(Items:clear()).
ls_put(Handle, Key, Value, absence('Unit')) :-
    state(Handle, State), ensure_open(State), items(State, Items),
    py_call(Items:'__setitem__'(Key, Value)).
ls_get(Handle, Key, R) :-
    state(Handle, State), ensure_open(State), items(State, Items),
    py_call(Items:'__contains__'(Key), Present),
    ( Present == @(true) -> py_call(Items:get(Key), Value), R = value('Maybe::Just', [Value])
    ; R = value('Maybe::Nothing', [])
    ).
ls_isOpen(Handle, R) :-
    state(Handle, State), py_call(State:get(open), Open),
    ( Open == @(true) -> R = true ; R = false ).
ls_size(Handle, Count) :- state(Handle, State), items(State, Items), py_call(builtins:len(Items), Count).

ls_writeNote(Directory, Number, absence('Unit')) :-
    directory_file_path(Directory, "note.txt", File),
    setup_call_cleanup(open(File, write, Stream, [encoding(utf8)]),
                       format(Stream, '~d', [Number]), close(Stream)).
ls_readNote(Directory, R) :-
    directory_file_path(Directory, "note.txt", File),
    ( exists_file(File) ->
        setup_call_cleanup(open(File, read, Stream, [encoding(utf8)]),
                           read_string(Stream, _, Text), close(Stream)),
        number_string(Number, Text), R = value('Maybe::Just', [Number])
    ; R = value('Maybe::Nothing', [])
    ).
ls_canListen(Port, true) :-
    setup_call_cleanup(tcp_socket(Socket),
        (tcp_bind(Socket, '127.0.0.1':Port), tcp_listen(Socket, 5)), tcp_close_socket(Socket)).
ls_setGreeting(Number, absence('Unit')) :-
    number_string(Number, Text), py_call(os:environ:'__setitem__'('LAWSPEC_EXAMPLE_GREETING', Text)).
ls_greeting(_, R) :-
    py_call(os:environ:get('LAWSPEC_EXAMPLE_GREETING'), Text, [py_string_as(string)]),
    ( Text == @(none) -> R = value('Maybe::Nothing', [])
    ; number_string(Number, Text), R = value('Maybe::Just', [Number])
    ).

ls_openPool(_, opaque(State)) :-
    flag(lawspec_fixture_resource_pools, Opened, Opened+1),
    ( Opened >= 1 -> throw(error(resource_error('pool must be shared'), _)) ; true ),
    py_call(builtins:dict(amount=0, open= @(true)), State, [py_object(true)]).
ls_drainPool(Handle, absence('Unit')) :-
    state(Handle, State), py_call(State:'__setitem__'(amount, 0)).
ls_closePool(Handle, absence('Unit')) :-
    state(Handle, State), py_call(State:'__setitem__'(open, @(false))).
ls_fill(Handle, Value, absence('Unit')) :-
    state(Handle, State), ensure_open(State), py_call(State:get(amount), Previous),
    Next is Previous+Value, py_call(State:'__setitem__'(amount, Next)).
ls_level(Handle, Amount) :- state(Handle, State), py_call(State:get(amount), Amount).

state(opaque(Holder), State) :- lawspec_prolog:native_handle(opaque(Holder), State).
items(State, Items) :- py_call(State:get(items), Items, [py_object(true)]).
ensure_open(State) :-
    py_call(State:get(open), Open),
    ( Open == @(true) -> true ; throw(error(resource_error(closed), _)) ).
