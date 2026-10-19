%% User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
-module(example_arithmetic).
-export([mirror/1, area/1, duplicate/1, count_pairs/1, drop_first/1]).

mirror({perfect_leaf, V}) -> {perfect_leaf, V};
mirror({perfect_node, {recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8, L, R}}) -> {perfect_node, {recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8, mirror(R), mirror(L)}}.
area({grid, {recordc0281b0d702b4d15fb4288afca7f776df7cdbc7cc164691755e2475920fa5bd9, Columns, Rows}}) -> count(Rows) * count(Columns).
duplicate(Xs) -> {halves, {record90e2e86ad982c9c5e71a6cd286ab605cf2b3d771c37021fb930810c33933eb3d, Xs, Xs}}.
count_pairs(Xs) -> {pairs, Xs}.
drop_first(Xs) -> {rest, Xs}.
count(row_end) -> 0;
count({row_cell, {record3b011c4276dbdecc2735ac0f8fa7ce5517233cc5b302ba305baeed3dec2f677f, _, T}}) -> 1 + count(T).
