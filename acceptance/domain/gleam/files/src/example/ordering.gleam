// ref:DEC-acceptance-with-mutants
import gleam/list
import lawspec/data

pub fn first_line(value: data.NonEmptyList(Int)) -> Int {
  let assert Ok(first) = list.first(value.value)
  first
}
pub fn validate_order(value: data.UnvalidatedOrder) -> Result(data.ValidatedOrder, data.OrderError) {
  case value {
    data.UnvalidatedOrder("", _) -> Error(data.OrderErrorInvalidOrderId)
    data.UnvalidatedOrder(_, quantity) if quantity < 1 || quantity > 1000 -> Error(data.OrderErrorInvalidQuantity)
    data.UnvalidatedOrder(id, quantity) -> Ok(data.ValidatedOrder(data.OrderId(id), data.UnitQuantity(quantity)))
  }
}
pub fn price_order(value: data.ValidatedOrder) -> Result(data.PricedOrder, data.OrderError) {
  let total = value.quantity.value * 25
  case total > 20000 {
    True -> Error(data.OrderErrorPriceTooHigh)
    False -> Ok(data.PricedOrder(value.id, value.quantity, total))
  }
}
