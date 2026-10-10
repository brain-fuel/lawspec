%% ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
-module(example_consistency).
-export([new_views/1,hit/1,total/1]).
new_views(ok) -> {views,beam_views:new()}.
hit({views,Id}) -> beam_views:hit(Id).
total({views,Id}) -> beam_views:total(Id).
