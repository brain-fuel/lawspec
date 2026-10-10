// ref:REQ-law-primitives ref:REQ-harness-units
import lawspec/data
import gleam/option
@external(erlang, "beam_example_resources", "open_store")
pub fn open_store(a0: Nil) -> data.Store
@external(erlang, "beam_example_resources", "close_store")
fn close_store_native(a0: data.Store) -> Nil
pub fn close_store(a0: data.Store) -> Nil { close_store_native(a0) Nil }
@external(erlang, "beam_example_resources", "clear_store")
fn clear_store_native(a0: data.Store) -> Nil
pub fn clear_store(a0: data.Store) -> Nil { clear_store_native(a0) Nil }
@external(erlang, "beam_example_resources", "put")
fn put_native(a0: data.Store, a1: Int, a2: Int) -> Nil
pub fn put(a0: data.Store, a1: Int, a2: Int) -> Nil { put_native(a0, a1, a2) Nil }
@external(erlang, "beam_example_resources", "get_gleam")
pub fn get(a0: data.Store, a1: Int) -> option.Option(Int)
@external(erlang, "beam_example_resources", "is_open")
pub fn is_open(a0: data.Store) -> Bool
@external(erlang, "beam_example_resources", "size")
pub fn size(a0: data.Store) -> Int
@external(erlang, "beam_example_resources", "write_note")
fn write_note_native(a0: String, a1: Int) -> Nil
pub fn write_note(a0: String, a1: Int) -> Nil { write_note_native(a0, a1) Nil }
@external(erlang, "beam_example_resources", "read_note_gleam")
pub fn read_note(a0: String) -> option.Option(Int)
@external(erlang, "beam_example_resources", "can_listen")
pub fn can_listen(a0: Int) -> Bool
@external(erlang, "beam_example_resources", "set_greeting")
fn set_greeting_native(a0: Int) -> Nil
pub fn set_greeting(a0: Int) -> Nil { set_greeting_native(a0) Nil }
@external(erlang, "beam_example_resources", "greeting_gleam")
pub fn greeting(a0: Nil) -> option.Option(Int)
@external(erlang, "beam_example_resources", "open_pool")
pub fn open_pool(a0: Nil) -> data.Pool
@external(erlang, "beam_example_resources", "drain_pool")
fn drain_pool_native(a0: data.Pool) -> Nil
pub fn drain_pool(a0: data.Pool) -> Nil { drain_pool_native(a0) Nil }
@external(erlang, "beam_example_resources", "close_pool")
fn close_pool_native(a0: data.Pool) -> Nil
pub fn close_pool(a0: data.Pool) -> Nil { close_pool_native(a0) Nil }
@external(erlang, "beam_example_resources", "fill")
fn fill_native(a0: data.Pool, a1: Int) -> Nil
pub fn fill(a0: data.Pool, a1: Int) -> Nil { fill_native(a0, a1) Nil }
@external(erlang, "beam_example_resources", "level")
pub fn level(a0: data.Pool) -> Int
