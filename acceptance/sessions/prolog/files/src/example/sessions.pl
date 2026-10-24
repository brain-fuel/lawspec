/** <module> Native processes exchange values through generated channel ends.

Janus query_once supplies the established thread-attached callback interface. Values are
arguments to the callback, never interpolated into Prolog query strings.
ref:DEC-prolog-janus
*/
:- module(example_sessions, [ls_add/3, ls_addHired/3, serve/2, manage/2]).
:- use_module(library(janus)).

serve(Server, true) :-
    py_call(Server:receive(), A-AfterA),
    py_call(AfterA:receive(), B-AfterB),
    Sum is A+B,
    py_call(AfterB:send(Sum), _).
ask(Client, A, B, Sum) :-
    py_call(Client:send(A), AfterA),
    py_call(AfterA:send(B), AfterB),
    py_call(AfterB:receive(), Sum-_).
manage(Manager, Result) :-
    py_call(Manager:receive(), Server-_), serve(Server, Result).

spawn(Predicate, End, Process) :-
    callback_goal(Predicate, Goal),
    py_call(builtins:getattr(eval(builtins:'__import__'(janus_swi)), query_once), Query),
    py_call(builtins:dict('End'=End), Arguments, [py_object(true)]),
    py_call(functools:partial(Query, Goal, Arguments), Callback),
    py_call(lawspec_runtime:spawn(Callback), Process).
callback_goal(serve, "example_sessions:serve(End, _Result)").
callback_goal(manage, "example_sessions:manage(End, _Result)").
joined(Process) :-
    py_call(Process:join(), Answer, [py_object(true)]), py_call(Answer:get(truth), @(true)).

ls_add(A, B, Sum) :-
    py_call(lawspec_sessions:'Serve':open(), Server-Client),
    spawn(serve, Server, Process),
    ask(Client, A, B, Sum), joined(Process).
ls_addHired(A, B, Sum) :-
    py_call(lawspec_sessions:'Hire':open(), Boss-Manager),
    py_call(lawspec_sessions:'Serve':open(), Server-Client),
    spawn(manage, Manager, Process),
    py_call(Boss:send(Server), _),
    ask(Client, A, B, Sum), joined(Process).
