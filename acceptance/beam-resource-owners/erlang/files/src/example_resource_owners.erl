%% ref:REQ-law-primitives ref:REQ-harness-units
-module(example_resource_owners).
-export([open_store/1, close_store/1, empty/1, touch/1]).
open_store(V) -> beam_owner_support:open(V).
close_store(V) -> beam_owner_support:close(V).
empty(V) -> beam_owner_support:empty(V).
touch(V) -> beam_owner_support:touch(V).
