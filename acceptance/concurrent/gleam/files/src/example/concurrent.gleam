// ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
import gleam/option.{type Option}
import lawspec/data
@external(erlang, "beam_collections", "new")
fn new(kind: Int) -> Int
@external(erlang, "beam_collections", "offer")
fn queue_offer(id: Int, value: Int) -> Bool
@external(erlang, "beam_collections", "poll_gleam")
fn queue_poll(id: Int) -> Option(Int)
@external(erlang, "beam_collections", "size")
fn size(id: Int) -> Int
@external(erlang, "beam_collections", "add")
fn set_add(id: Int, value: Int) -> Bool
@external(erlang, "beam_collections", "remove")
fn set_remove(id: Int, value: Int) -> Bool
@external(erlang, "beam_collections", "contains")
fn set_contains(id: Int, value: Int) -> Bool
@external(erlang, "beam_collections", "put_gleam")
fn map_put(id: Int, key: Int, value: Int) -> Option(Int)
@external(erlang, "beam_collections", "get_gleam")
fn map_get(id: Int, key: Int) -> Option(Int)
@external(erlang, "beam_collections", "evict_gleam")
fn map_remove(id: Int, key: Int) -> Option(Int)
pub fn new_queue(_unit: Nil) -> data.WorkQueue { data.WorkQueue(new(0)) }
pub fn offer(queue: data.WorkQueue, value: Int) -> Nil {
  let assert True = queue_offer(queue.id, value)
  Nil
}
pub fn poll(queue: data.WorkQueue) -> Option(Int) { queue_poll(queue.id) }
pub fn queue_size(queue: data.WorkQueue) -> Int { size(queue.id) }
pub fn new_tags(_unit: Nil) -> data.Tags { data.Tags(new(1)) }
pub fn tag(tags: data.Tags, value: Int) -> Bool { set_add(tags.id, value) }
pub fn untag(tags: data.Tags, value: Int) -> Bool { set_remove(tags.id, value) }
pub fn tagged(tags: data.Tags, value: Int) -> Bool { set_contains(tags.id, value) }
pub fn new_cache(_unit: Nil) -> data.Cache { data.Cache(new(2)) }
pub fn store(cache: data.Cache, key: Int, value: Int) -> Option(Int) { map_put(cache.id, key, value) }
pub fn fetch(cache: data.Cache, key: Int) -> Option(Int) { map_get(cache.id, key) }
pub fn evict(cache: data.Cache, key: Int) -> Option(Int) { map_remove(cache.id, key) }
