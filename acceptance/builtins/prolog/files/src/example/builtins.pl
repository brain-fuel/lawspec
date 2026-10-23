/** <module> Native code calls its declared built-in capability arguments.
ref:DEC-prolog-janus
*/
:- module(example_builtins, [ls_elapsed/3, ls_token/3, ls_listening/3, ls_charge/3]).
:- use_module(library(socket)).

ls_elapsed(Clock, Count, value('lawspec.time::type::Duration::Duration', [Elapsed])) :-
    lawspec_prolog:operation(Clock, now, [], value(_, [Start])),
    read_ticks(Count, Clock),
    lawspec_prolog:operation(Clock, now, [], value(_, [End])), Elapsed is End-Start.
read_ticks(Count, Clock) :-
    ( Count =< 0 -> true
    ; lawspec_prolog:operation(Clock, now, [], _), Rest is Count-1, read_ticks(Rest, Clock)
    ).
ls_token(Random, Count, R) :- lawspec_prolog:operation(Random, secureBytes, [Count], R).
ls_listening(Ports, _, true) :-
    lawspec_prolog:operation(Ports, freePort, [], Port),
    setup_call_cleanup(tcp_socket(Socket),
        (tcp_bind(Socket, '127.0.0.1':Port), tcp_listen(Socket, 5)), tcp_close_socket(Socket)).
ls_charge(Log, Cents, R) :-
    ( Cents mod 2 =:= 0 ->
        format(string(Message), 'charged ~d', [Cents]),
        lawspec_prolog:operation(Log, logMessage,
            [value('lawspec.logging::type::LogLevel::Info', []), Message], _), R = true
    ; R = false
    ).
