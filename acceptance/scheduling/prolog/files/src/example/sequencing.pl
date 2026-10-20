/** <module> Native sleep intervals observed by the shared scheduling oracle.
ref:DEC-prolog-janus
*/
:- module(lawspec_bdc97732b4216a47, [ls_pause/2]).

ls_pause(Number, true) :-
    note(start, Number), sleep(0.005), note(end, Number).

note(Event, Number) :-
    ( getenv('LAWSPEC_SCHEDULE_LOG', File) ->
        get_time(Seconds), Milliseconds is Seconds*1000,
        setup_call_cleanup(open(File, append, Stream),
            format(Stream, '~w ~d ~3f~n', [Event, Number, Milliseconds]), close(Stream))
    ; true
    ).
