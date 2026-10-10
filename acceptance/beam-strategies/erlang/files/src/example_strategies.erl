%% ref:REQ-harness-units
-module(example_strategies).
-export([numbers/1, parcels/1, dependent/2, defaults/1, wide/1, finite/1, shadowed/1]).

numbers(N) -> beam_strategy_support:record(numbers, N).
parcels(P) -> beam_strategy_support:record(parcels, P).
dependent(X, Y) -> beam_strategy_support:record(dependent, {X, Y}), Y.
defaults(N) -> beam_strategy_support:record(defaults, N).
wide(N) -> beam_strategy_support:record(wide, N).
finite(Flag) -> beam_strategy_support:record(finite, Flag).
shadowed(N) -> beam_strategy_support:record(shadowed, N).
