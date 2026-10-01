// User-owned LawSpec adapter.
package ordering

// FirstLine returns the first element of a non-empty list.
func FirstLine(value0 NonEmptyList[int32]) int32 {
	return value0.Value[0]
}

// ValidateOrder checks the raw order and wraps its values.
func ValidateOrder(value0 UnvalidatedOrder) LawSpecEither[OrderError, ValidatedOrder] {
	if len(value0.Id) == 0 {
		return LawSpecLeft[OrderError, ValidatedOrder](OrderErrorInvalidOrderId{})
	}
	if !(value0.Quantity >= 1 && value0.Quantity <= 1000) {
		return LawSpecLeft[OrderError, ValidatedOrder](OrderErrorInvalidQuantity{})
	}
	return LawSpecRight[OrderError, ValidatedOrder](ValidatedOrder{
		Id: OrderId{Value: value0.Id}, Quantity: UnitQuantity{Value: value0.Quantity}})
}

// PriceOrder prices a validated order.
func PriceOrder(value0 ValidatedOrder) LawSpecEither[OrderError, PricedOrder] {
	total := int64(value0.Quantity.Value) * 25
	if total > 20000 {
		return LawSpecLeft[OrderError, PricedOrder](OrderErrorPriceTooHigh{})
	}
	return LawSpecRight[OrderError, PricedOrder](PricedOrder{Id: value0.Id, Quantity: value0.Quantity, Total: total})
}

// PlaceOrder validates and then prices an order.
func PlaceOrder(value0 UnvalidatedOrder) LawSpecEither[OrderError, PricedOrder] {
	validated := ValidateOrder(value0)
	if failure, ok := validated.Left(); ok {
		return LawSpecLeft[OrderError, PricedOrder](failure)
	}
	order, _ := validated.Right()
	return PriceOrder(order)
}
