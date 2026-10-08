%% User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
-module(example_arithmetic).
-export([mirror/1, area/1, duplicate/1, count_pairs/1, drop_first/1]).

mirror({perfect_leaf, V}) -> {perfect_leaf, V};
mirror({perfect_node, L, R}) -> {perfect_node, mirror(R), mirror(L)}.
area({grid, Rows, Columns}) -> count(Rows) * count(Columns).
duplicate(Xs) -> {halves, Xs, Xs}.
count_pairs(Xs) -> {pairs, Xs}.
drop_first(Xs) -> {rest, Xs}.
count(row_end) -> 0;
count({row_cell, _, T}) -> 1 + count(T).
