/*  Checks, or rewrites, Prolog source to SWI-Prolog's conventional layout:
    every clause and directive exactly as portray_clause/2 (library(listing))
    prints it, variable names kept. Comments and blank lines between clauses
    are left as they are.

    swipl tools/prolog-layout.pl [--write] FILE-OR-DIRECTORY...
*/
:- initialization(main, main).

main :-
    current_prolog_flag(argv, Argv),
    (   select('--write', Argv, Paths) -> Mode = write ; Mode = check, Paths = Argv ),
    findall(F, (member(P, Paths), prolog_file(P, F)), Files0),
    sort(Files0, Files),
    foldl(layout_file(Mode), Files, 0, Failures),
    (   Failures =:= 0 -> true ; halt(1) ).

prolog_file(Path, File) :-
    (   exists_directory(Path)
    ->  directory_member(Path, File, [extensions([pl]), recursive(true)])
    ;   File = Path
    ).

layout_file(Mode, File, Failures0, Failures) :-
    read_file_to_string(File, Text, []),
    setup_call_cleanup(open_string(Text, In),
                       read_clauses(In, Spans),
                       close(In)),
    rebuild(Spans, Text, 0, Pieces, Differences),
    atomics_to_string(Pieces, Laid),
    (   Differences == []
    ->  Failures = Failures0
    ;   Mode == write
    ->  setup_call_cleanup(open(File, write, Out, [encoding(utf8)]), write(Out, Laid), close(Out)),
        Failures = Failures0
    ;   forall(member(Line-Actual-Expected, Differences),
               format(user_error, "~w:~w: not in SWI-Prolog layout~n  found:    ~w~n  expected: ~w~n",
                      [File, Line, Actual, Expected])),
        Failures is Failures0 + 1
    ).

read_clauses(In, Spans) :-
    read_term(In, Term, [subterm_positions(Pos), variable_names(Names), syntax_errors(error)]),
    (   Term == end_of_file
    ->  Spans = []
    ;   arg(1, Pos, From), arg(2, Pos, To),
        maplist([Name=Var]>>(Var = '$VAR'(Name)), Names),
        with_output_to(string(Printed), portray_clause(Term)),
        Spans = [span(From, To, Printed)|Rest],
        read_clauses(In, Rest)
    ).

% Each clause's text, through its full stop, is replaced by portray_clause's.
rebuild([], Text, At, [Tail], []) :-
    sub_string(Text, At, _, 0, Tail).
rebuild([span(From, To, Printed)|Rest], Text, At, [Before, Expected|Pieces], Differences) :-
    Gap is From - At,
    sub_string(Text, At, Gap, _, Before),
    Length is To - From,
    sub_string(Text, From, Length, _, Body),
    string_concat(Expected, "\n", Printed),
    string_concat(Body, ".", Actual),
    End is To + 1,
    (   Actual == Expected
    ->  Differences = More
    ;   sub_string(Text, 0, From, _, Prefix),
        split_string(Prefix, "\n", "", Lines), length(Lines, Line),
        Differences = [Line-Actual-Expected|More]
    ),
    rebuild(Rest, Text, End, Pieces, More).
