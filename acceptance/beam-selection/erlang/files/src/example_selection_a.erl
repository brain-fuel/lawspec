%% ref:DEC-native-property-frameworks
-module(example_selection_a).
-export([observed/1]).
observed(N) -> beam_selection_support:record(N).
