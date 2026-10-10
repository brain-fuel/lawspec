// ref:DEC-acceptance-with-mutants ref:DEC-async-native-tasks
pub type Shelf

@external(erlang, "warehouse_native_ffi", "price_of")
pub fn price_of(sku: String) -> Int

@external(erlang, "warehouse_native_ffi", "quote_of")
pub fn quote_of(sku: String) -> Int

@external(erlang, "warehouse_native_ffi", "new")
pub fn new() -> Shelf

@external(erlang, "warehouse_native_ffi", "restock")
pub fn restock(shelf: Shelf, amount: Int) -> Nil

@external(erlang, "warehouse_native_ffi", "count")
pub fn count(shelf: Shelf) -> Int
