%% ref:REQ-law-primitives ref:REQ-harness-units
-module(example_resources).
-export([open_store/1, close_store/1, clear_store/1, put/3, get/2, is_open/1, size/1, write_note/2, read_note/1, can_listen/1, set_greeting/1, greeting/1, open_pool/1, drain_pool/1, close_pool/1, fill/2, level/1]).
open_store(A0) -> beam_example_resources:open_store(A0).
close_store(A0) -> beam_example_resources:close_store(A0).
clear_store(A0) -> beam_example_resources:clear_store(A0).
put(A0, A1, A2) -> beam_example_resources:put(A0, A1, A2).
get(A0, A1) -> beam_example_resources:get(A0, A1).
is_open(A0) -> beam_example_resources:is_open(A0).
size(A0) -> beam_example_resources:size(A0).
write_note(A0, A1) -> beam_example_resources:write_note(A0, A1).
read_note(A0) -> beam_example_resources:read_note(A0).
can_listen(A0) -> beam_example_resources:can_listen(A0).
set_greeting(A0) -> beam_example_resources:set_greeting(A0).
greeting(A0) -> beam_example_resources:greeting(A0).
open_pool(A0) -> beam_example_resources:open_pool(A0).
drain_pool(A0) -> beam_example_resources:drain_pool(A0).
close_pool(A0) -> beam_example_resources:close_pool(A0).
fill(A0, A1) -> beam_example_resources:fill(A0, A1).
level(A0) -> beam_example_resources:level(A0).
