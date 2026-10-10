%% ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
-module(example_concurrent).
-export([new_queue/1,offer/2,poll/1,queue_size/1,new_tags/1,tag/2,untag/2,tagged/2,
    new_cache/1,store/3,fetch/2,evict/2]).
new_queue(ok) -> {work_queue,beam_collections:new(0)}.
offer({work_queue,Id},Value) -> true=beam_collections:offer(Id,Value), ok.
poll({work_queue,Id}) -> beam_collections:poll(Id).
queue_size({work_queue,Id}) -> beam_collections:size(Id).
new_tags(ok) -> {tags,beam_collections:new(1)}.
tag({tags,Id},Value) -> beam_collections:add(Id,Value).
untag({tags,Id},Value) -> beam_collections:remove(Id,Value).
tagged({tags,Id},Value) -> beam_collections:contains(Id,Value).
new_cache(ok) -> {cache,beam_collections:new(2)}.
store({cache,Id},Key,Value) -> beam_collections:put(Id,Key,Value).
fetch({cache,Id},Key) -> beam_collections:get(Id,Key).
evict({cache,Id},Key) -> beam_collections:evict(Id,Key).
