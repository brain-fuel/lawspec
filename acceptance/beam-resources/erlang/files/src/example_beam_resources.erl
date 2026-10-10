%% ref:REQ-law-primitives
-module(example_beam_resources).
-export([open_store/1, close_store/1, size/1, write/2, is_open/1, directory_empty/1, write_note/2, note_matches/2, file_empty/1, set_greeting/1, greeting_matches/1, greeting_absent/1]).

open_store(A0) -> beam_resource_support:open_store(A0).
close_store(A0) -> beam_resource_support:close_store(A0).
size(A0) -> beam_resource_support:size(A0).
write(A0, A1) -> beam_resource_support:write(A0, A1).
is_open(A0) -> beam_resource_support:is_open(A0).
directory_empty(A0) -> beam_resource_support:directory_empty(A0).
write_note(A0, A1) -> beam_resource_support:write_note(A0, A1).
note_matches(A0, A1) -> beam_resource_support:note_matches(A0, A1).
file_empty(A0) -> beam_resource_support:file_empty(A0).
set_greeting(A0) -> beam_resource_support:set_greeting(A0).
greeting_matches(A0) -> beam_resource_support:greeting_matches(A0).
greeting_absent(A0) -> beam_resource_support:greeting_absent(A0).
