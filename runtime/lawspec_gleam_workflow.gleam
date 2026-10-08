// Scoped workflow state is shared by generated calls and their async workers.
// The callback owns the runtime; it must not escape that callback.
// ref:DEC-domain-modeling-primitives ref:DEC-idiomatic-generated-types
pub type Runtime

pub type Event {
  Event(kind: String, stage: String, number: Int, succeeded: Bool)
}

@external(erlang, "lawspec_beam_workflow", "with_virtual")
pub fn with_virtual(seed: Int, body: fn(Runtime) -> a) -> a

@external(erlang, "lawspec_beam_workflow", "with_real")
pub fn with_real(seed: Int, body: fn(Runtime) -> a) -> a

@external(erlang, "lawspec_beam_workflow", "with_clock_callbacks")
pub fn with_clock(
  now: fn() -> Int,
  sleep: fn(Int) -> Nil,
  virtual: Bool,
  seed: Int,
  body: fn(Runtime) -> a,
) -> a

@external(erlang, "lawspec_beam_workflow", "now")
pub fn now(runtime: Runtime) -> Int

@external(erlang, "lawspec_beam_workflow", "native_sleep")
pub fn sleep(runtime: Runtime, micros: Int) -> Nil

// Only a runtime created with with_virtual has a directly adjustable clock.
@external(erlang, "lawspec_beam_workflow", "native_set_time")
pub fn set_time(runtime: Runtime, micros: Int) -> Nil

@external(erlang, "lawspec_beam_workflow", "native_trace")
pub fn trace(runtime: Runtime) -> List(Event)
