//// ref:REQ-law-primitives ref:REQ-harness-units
import lawspec/data.{type Store, type GroupStore, type SharedPool}
import lawspec/abilities/example/shared_resources as abilities
import lawspec/effects

@external(erlang, "beam_shared_resource_support", "open_store")
pub fn open_store(tick: Int) -> Store

@external(erlang, "beam_shared_resource_support", "reset_store")
fn reset_store_native(store: Store, tick: Int) -> Nil

pub fn reset_store(store: Store, tick: Int) -> Nil {
  reset_store_native(store, tick)
  Nil
}

@external(erlang, "beam_shared_resource_support", "close_store")
fn close_store_native(store: Store, tick: Int) -> Nil

pub fn close_store(store: Store, tick: Int) -> Nil {
  close_store_native(store, tick)
  Nil
}

@external(erlang, "beam_shared_resource_support", "use_store")
pub fn use_store(store: Store, value: Int) -> Bool

@external(erlang, "beam_shared_resource_support", "store_value")
pub fn store_value(store: Store) -> Int

@external(erlang, "beam_shared_resource_support", "open_group")
pub fn open_group(unit: Nil) -> GroupStore

@external(erlang, "beam_shared_resource_support", "reset_group")
fn reset_group_native(store: GroupStore) -> Nil

pub fn reset_group(store: GroupStore) -> Nil {
  reset_group_native(store)
  Nil
}

@external(erlang, "beam_shared_resource_support", "close_group")
fn close_group_native(store: GroupStore) -> Nil

pub fn close_group(store: GroupStore) -> Nil {
  close_group_native(store)
  Nil
}

@external(erlang, "beam_shared_resource_support", "use_group")
pub fn use_group(store: GroupStore) -> Bool

@external(erlang, "beam_shared_resource_support", "open_pool")
pub fn open_pool(unit: Nil) -> SharedPool

@external(erlang, "beam_shared_resource_support", "reset_pool")
fn reset_pool_native(pool: SharedPool) -> Nil

pub fn reset_pool(pool: SharedPool) -> Nil {
  reset_pool_native(pool)
  Nil
}

@external(erlang, "beam_shared_resource_support", "close_pool")
fn close_pool_native(pool: SharedPool) -> Nil

pub fn close_pool(pool: SharedPool) -> Nil {
  close_pool_native(pool)
  Nil
}

@external(erlang, "beam_shared_resource_support", "use_pool")
pub fn use_pool(pool: SharedPool) -> Bool

pub fn audit_handler() -> abilities.Audit {
  let count = effects.new_cell(0)
  abilities.audit(fn(_) {
    let next = effects.read_cell(count) + 1
    effects.write_cell(count, next)
    next
  })
}
