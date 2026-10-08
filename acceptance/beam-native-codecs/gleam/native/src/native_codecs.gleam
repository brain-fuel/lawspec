import gleam/list
import gleam/option.{type Option, None, Some}
import lawspec/data

pub opaque type Parcel(a) { Private(a) }
pub opaque type FlatChain(a) { Flat(List(a), Bool) }
pub opaque type Positive { Positive(Int) }

pub fn copy_parcel(value: Parcel(a)) -> Parcel(a) { let Private(item) = value Private(item) }
pub fn copy_nested(value: Parcel(Option(Parcel(Int)))) -> Parcel(Option(Parcel(Int))) {
  let Private(item) = value
  Private(option.map(item, copy_parcel))
}
pub fn copy_chain(value: FlatChain(a)) -> FlatChain(a) { let Flat(items, ended) = value Flat(items, ended) }
pub fn copy_positive(value: Positive) -> Positive { let Positive(item) = value Positive(item) }

pub fn to_parcel(value: data.Parcel(a), convert: fn(a) -> b) -> Parcel(b) { Private(convert(value.item)) }
pub fn from_parcel(value: Parcel(a), convert: fn(a) -> b) -> data.Parcel(b) { let Private(item) = value data.Parcel(convert(item)) }
pub fn to_chain(value: data.Chain(a), convert: fn(a) -> b) -> FlatChain(b) { flatten(value, convert, []) }
fn flatten(value: data.Chain(a), convert: fn(a) -> b, items: List(b)) -> FlatChain(b) {
  case value {
    data.ChainStop -> Flat(list.reverse(items), True)
    data.ChainMore(item, None) -> Flat(list.reverse([convert(item), ..items]), False)
    data.ChainMore(item, Some(tail)) -> flatten(tail, convert, [convert(item), ..items])
  }
}
pub fn from_chain(value: FlatChain(a), convert: fn(a) -> b) -> data.Chain(b) {
  let Flat(items, ended) = value
  let tail = case ended { True -> Some(data.ChainStop) False -> None }
  let assert Some(result) = list.fold(list.reverse(items), tail, fn(rest, item) { Some(data.ChainMore(convert(item), rest)) })
  result
}
pub fn to_positive(value: data.Positive) -> Positive { Positive(value.value) }
pub fn from_positive(value: Positive) -> data.Positive { let Positive(item) = value data.Positive(item) }
