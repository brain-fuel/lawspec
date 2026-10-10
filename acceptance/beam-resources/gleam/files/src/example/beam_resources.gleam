//// ref:REQ-law-primitives
import lawspec/data.{type Store}

@external(erlang, "beam_resource_support", "open_store")
pub fn open_store(a0: Nil) -> Store

@external(erlang, "beam_resource_support", "close_store")
fn close_store_native(a0: Store) -> Nil

pub fn close_store(a0: Store) -> Nil {
  close_store_native(a0)
  Nil
}

@external(erlang, "beam_resource_support", "size")
pub fn size(a0: Store) -> Int

@external(erlang, "beam_resource_support", "write")
pub fn write(a0: Store, a1: Int) -> Bool

@external(erlang, "beam_resource_support", "is_open")
pub fn is_open(a0: Store) -> Bool

@external(erlang, "beam_resource_support", "directory_empty")
pub fn directory_empty(a0: String) -> Bool

@external(erlang, "beam_resource_support", "write_note")
pub fn write_note(a0: String, a1: Int) -> Bool

@external(erlang, "beam_resource_support", "note_matches")
pub fn note_matches(a0: String, a1: Int) -> Bool

@external(erlang, "beam_resource_support", "file_empty")
pub fn file_empty(a0: String) -> Bool

@external(erlang, "beam_resource_support", "set_greeting")
pub fn set_greeting(a0: Int) -> Bool

@external(erlang, "beam_resource_support", "greeting_matches")
pub fn greeting_matches(a0: Int) -> Bool

@external(erlang, "beam_resource_support", "greeting_absent")
pub fn greeting_absent(a0: Nil) -> Bool

