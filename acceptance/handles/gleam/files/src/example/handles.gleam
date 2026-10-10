// ref:DEC-tests-cite-requirements ref:DEC-stateful-models-linearizability
import gleam/option.{type Option}
import lawspec/data
@external(erlang, "beam_jobs", "new")
fn new() -> data.Jobs
@external(erlang, "beam_jobs", "submit")
fn offer(jobs: data.Jobs, value: Int) -> Bool
@external(erlang, "beam_jobs", "take_gleam")
fn poll(jobs: data.Jobs) -> Option(Int)
@external(erlang, "beam_jobs", "pending")
fn size(jobs: data.Jobs) -> Int
pub fn new_jobs(_unit: Nil) -> data.Jobs { new() }
pub fn submit(jobs: data.Jobs, value: Int) -> Nil { let assert True = offer(jobs, value) Nil }
pub fn take(jobs: data.Jobs) -> Option(Int) { poll(jobs) }
pub fn pending(jobs: data.Jobs) -> Int { size(jobs) }
