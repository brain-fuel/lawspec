%% ref:REQ-law-primitives ref:REQ-harness-units ref:DEC-tests-cite-requirements
-module(beam_owner_support).
-export([open/1, close/1, empty/1, touch/1]).
open(_) ->
    Table = ets:new(owner_store, [private]),
    put(owner_store, Table),
    self().
close(Owner) ->
    Owner = self(),
    Table = get(owner_store),
    true = ets:delete(Table),
    ok.
empty(Owner) ->
    true = Owner =/= self(),
    lawspec_beam_resource:call(Owner, fun() -> ets:info(get(owner_store), size) =:= 0 end).
touch(Owner) ->
    lawspec_beam_resource:call(Owner, fun() -> ets:insert(get(owner_store), {note, 1}) end).
