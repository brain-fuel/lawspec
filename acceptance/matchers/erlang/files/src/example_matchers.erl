%% ref:DEC-acceptance-with-mutants
-module(example_matchers).
-export([sort_items/1, unique_tags/1, average/2, slug/1, ship/1]).

sort_items(Items) -> lists:sort(Items).
unique_tags(Tags) -> lists:uniq(Tags).
average(A, B) -> lawspec_beam_scalar:float_from_native(64, (A + B) / 2).
ship(Id) -> {order_shipped, {recordaaeb2c3925832586ac7d5e3c9a9cd234d3a26f7d9d0e264664a4ae58c6f71911, <<"post">>, Id}}.

slug(Title) ->
    Words = case re:run(string:lowercase(Title), <<"[a-z0-9]+">>,
                       [global, {capture, [0], binary}]) of
        nomatch -> [];
        {match, Matches} -> [Word || [Word] <- Matches]
    end,
    iolist_to_binary(lists:join(<<"-">>, Words)).
