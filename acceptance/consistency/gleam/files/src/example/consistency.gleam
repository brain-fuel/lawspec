// ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
import lawspec/data
@external(erlang, "beam_views", "new")
fn new() -> Int
@external(erlang, "beam_views", "hit")
fn hit_replica(id: Int) -> Int
@external(erlang, "beam_views", "total")
fn sum_replicas(id: Int) -> Int
pub fn new_views(_unit: Nil) -> data.Views { data.Views(new()) }
pub fn hit(views: data.Views) -> Int { hit_replica(views.id) }
pub fn total(views: data.Views) -> Int { sum_replicas(views.id) }
