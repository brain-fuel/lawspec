%% Portable generator conformance through the published descriptor runtime.
%% ref:DEC-portable-seeded-generation ref:DEC-acceptance-with-mutants
-module(beam_generation_support).
-export([generated/4, shrunk/3]).

generated(Text, Seed, Size, Count) ->
    {Table, Descriptor} = lawspec_beam_values:from_text(Text),
    State = lawspec_beam_random:seed(Seed),
    {Values, _} = lists:mapfoldl(fun(_, S) ->
        lawspec_beam_values:generate(Descriptor, Table, S, Size)
    end, State, lists:duplicate(max(0, Count), next)),
    [lawspec_beam_values:render(V) || V <- Values].

shrunk(Text, Seed, Size) ->
    {Table, Descriptor} = lawspec_beam_values:from_text(Text),
    {Value, _} = lawspec_beam_values:generate(Descriptor, Table, lawspec_beam_random:seed(Seed), Size),
    [lawspec_beam_values:render(V) || V <- lawspec_beam_values:shrink(Descriptor, Value, Table)].
