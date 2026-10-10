// ref:REQ-law-primitives ref:REQ-harness-units
import lawspec/data.{type Store}
@external(erlang, "beam_owner_support", "open")
pub fn open_store(value: Nil) -> Store
@external(erlang, "beam_owner_support", "close")
fn close_native(value: Store) -> Nil
pub fn close_store(value: Store) -> Nil { close_native(value) Nil }
@external(erlang, "beam_owner_support", "empty")
pub fn empty(value: Store) -> Bool
@external(erlang, "beam_owner_support", "touch")
pub fn touch(value: Store) -> Bool
