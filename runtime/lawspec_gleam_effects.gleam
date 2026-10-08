// Scoped native handlers retain their logical context across checked calls.
// ref:DEC-typed-core-boundary
pub type Context

pub type HandlerOrigin

// Cells allocated by a native production factory or with_context belong to
// that scope. Their storage is shared by concurrent callers and released when
// the scope ends, including failure and cancellation.
pub type Cell(a)

@external(erlang, "lawspec_beam_effects", "native_cell")
pub fn new_cell(initial: a) -> Cell(a)

@external(erlang, "lawspec_beam_effects", "native_read")
pub fn read_cell(cell: Cell(a)) -> a

@external(erlang, "lawspec_beam_effects", "native_write")
fn store_cell(cell: Cell(a), value: a) -> a

pub fn write_cell(cell: Cell(a), value: a) -> Nil {
  let _ = store_cell(cell, value)
  Nil
}

@external(erlang, "lawspec_beam_effects", "native_origin")
pub fn native_origin() -> HandlerOrigin

@external(erlang, "lawspec_abilities", "with_context")
pub fn with_context(body: fn(Context) -> a) -> a
