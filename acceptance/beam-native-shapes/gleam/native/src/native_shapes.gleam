import gleam/list
import gleam/option.{type Option, None, Some}

pub type Wrapped(a) { Wrapped(stored: a) }
// Field order differs from the Core declaration and the binding JSON order.
pub type Link(a) { End Next(remainder: Option(Link(a)), item: a) }
pub type Forest(a) { Item(datum: a) Group(trees: List(Forest(a))) }
pub type Seal { Seal }

pub fn copy_box(value: Wrapped(a)) -> Wrapped(a) { Wrapped(value.stored) }
pub fn copy_chain(value: Link(a)) -> Link(a) {
  case value {
    End -> End
    Next(tail, item) -> Next(option.map(tail, copy_chain), item)
  }
}
pub fn copy_tree(value: Forest(a)) -> Forest(a) {
  case value {
    Item(item) -> Item(item)
    Group(trees) -> Group(list.map(trees, copy_tree))
  }
}
pub fn copy_nested(value: Wrapped(Option(Wrapped(Int)))) -> Wrapped(Option(Wrapped(Int))) {
  case value.stored {
    None -> Wrapped(None)
    Some(box) -> Wrapped(Some(copy_box(box)))
  }
}
pub fn copy_stamp(value: Seal) -> Seal { let Seal = value Seal }
