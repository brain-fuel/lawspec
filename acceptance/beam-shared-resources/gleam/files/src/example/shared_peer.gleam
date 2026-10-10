//// ref:REQ-law-primitives ref:REQ-harness-units
import lawspec/data.{type SharedPool}

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
