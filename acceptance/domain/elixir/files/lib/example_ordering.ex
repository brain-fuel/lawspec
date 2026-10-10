# ref:DEC-acceptance-with-mutants
defmodule Example.Ordering do
  alias LawSpec.Data, as: D
  def first_line(%D.NonEmptyList{value: values}), do: hd(values)
  def validate_order(%D.UnvalidatedOrder{id: ""}), do: {:left, %D.OrderErrorInvalidOrderId{}}
  def validate_order(%D.UnvalidatedOrder{quantity: quantity}) when quantity < 1 or quantity > 1000, do: {:left, %D.OrderErrorInvalidQuantity{}}
  def validate_order(%D.UnvalidatedOrder{id: id, quantity: quantity}) do
    {:right, %D.ValidatedOrder{id: %D.OrderId{value: id}, quantity: %D.UnitQuantity{value: quantity}}}
  end
  def price_order(%D.ValidatedOrder{id: id, quantity: quantity}) do
    total = quantity.value * 25
    if total > 20000, do: {:left, %D.OrderErrorPriceTooHigh{}}, else: {:right, %D.PricedOrder{id: id, quantity: quantity, total: total}}
  end
end
