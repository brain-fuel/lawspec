% User-owned LawSpec adapter for example.vacuity from vacuity.lawspec.
:- module(example_vacuity,
          [ ls_shout/2,
            ls_abbreviate/2,
            ls_accepts/2,
            ls_describe/2,
            ls_keep/2
          ]).

% shout — vacuity.lawspec:26
ls_shout(Name, Shouted) :-
    string_upper(Name, Shouted).

% abbreviate — vacuity.lawspec:27
ls_abbreviate(value(_, [Token, _Meaning]), Token).

% accepts — vacuity.lawspec:28
% Accepts only codes such as OFFER-2026-AB: no random record has one.
ls_accepts(value(_, [Code, Amount]), Accepted) :-
    (   string_chars(Code, ['O', 'F', 'F', 'E', 'R', '-', A, B, C, D, '-', X, Y]),
        forall(member(Digit, [A, B, C, D]), char_type(Digit, digit(_))),
        forall(member(Letter, [X, Y]), (char_code(Letter, L), L >= 0'A, L =< 0'Z)),
        Amount > 0
    ->  Accepted = true
    ;   Accepted = false
    ).

% describe — vacuity.lawspec:29
ls_describe(value(_, [Code, _Amount]), Code).

% keep — vacuity.lawspec:30
ls_keep(Key, Key).
