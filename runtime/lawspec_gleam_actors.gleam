// Stable actor addresses and native OTP processes are different identities:
// a handler restart changes the process and preserves the address.
// ref:DEC-actors-otp-supervision ref:DEC-idiomatic-generated-types
import gleam/dynamic

pub type Process
pub type Handle
pub type ChildSpec

pub type Event {
  Crashed(dynamic.Dynamic)
  Stopped
}

@external(erlang, "erlang", "self")
pub fn self() -> Process

// Register the current process with an actor's or supervisor's monitor
// function first. Messages about other handles stay in the mailbox.
@external(erlang, "lawspec_beam_actors", "receive_event")
pub fn receive_event(handle: a, timeout_milliseconds: Int) -> Result(Event, Nil)
