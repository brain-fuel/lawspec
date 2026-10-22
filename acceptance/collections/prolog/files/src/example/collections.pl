/** <module> Native collection algorithms independent of the checked models.

SWI sorting and run-length counting operate on ground integer, string and list
values; the bridge validates the declared collection constructors and order.
ref:DEC-prolog-janus
*/
:- module(lawspec_414634f918a7f748,
          [ls_dedupe/2, ls_wordCounts/2, ls_fifo/2, ls_lifo/2,
           ls_rotate/2, ls_distinctRows/2]).
:- use_module(library(lists)).

ls_dedupe(Items, value('lawspec.collections::type::Set::SetItems', [Distinct])) :-
    sort(Items, Distinct).

ls_wordCounts(Words, value('lawspec.collections::type::KeyVal::KeyValEntries', [Entries])) :-
    msort(Words, Sorted),
    clumped(Sorted, Counts),
    maplist(count_entry, Counts, Entries).

count_entry(Word-Count, value('lawspec.collections::type::Entry::Entry', [Word, Count])).

ls_fifo(Items, value('lawspec.collections::type::Queue::QueueItems', [Items])).

% The logical Stack stores its top first; the input arrives bottom first.
ls_lifo(Items, value('lawspec.collections::type::Stack::StackItems', [TopFirst])) :-
    reverse(Items, TopFirst).

ls_rotate(value(Tag, [Items]), value(Tag, [Rotated])) :-
    ( Items = [] -> Rotated = []
    ; Items = [Front|Rest], append(Rest, [Front], Rotated)
    ).

ls_distinctRows(Rows, value('lawspec.collections::type::Set::SetItems', [Distinct])) :-
    sort(Rows, Distinct).
