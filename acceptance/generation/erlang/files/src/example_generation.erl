%% ref:DEC-portable-seeded-generation ref:DEC-acceptance-with-mutants
-module(example_generation).
-export([generated/4, shrunk/3]).
generated(Text, Seed, Size, Count) -> beam_generation_support:generated(Text, Seed, Size, Count).
shrunk(Text, Seed, Size) -> beam_generation_support:shrunk(Text, Seed, Size).
