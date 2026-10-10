%% ref:DEC-acceptance-with-mutants
-module(example_collections).
-export([dedupe/1, word_counts/1, fifo/1, lifo/1, rotate/1, distinct_rows/1]).
dedupe(Values) -> {set, lists:usort(Values)}.
word_counts(Words) ->
    Counts = lists:foldl(fun(Word, Acc) -> maps:update_with(Word, fun(N) -> N + 1 end, 1, Acc) end, #{}, Words),
    {key_val, [{entry, Word, Count} || {Word, Count} <- lists:sort(maps:to_list(Counts))]}.
fifo(Values) -> {queue, Values}.
lifo(Values) -> {stack, lists:reverse(Values)}.
rotate({deque, []} = Empty) -> Empty;
rotate({deque, [Head | Rest]}) -> {deque, Rest ++ [Head]}.
distinct_rows(Rows) -> {set, lists:usort(Rows)}.
