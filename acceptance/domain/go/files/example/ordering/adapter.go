// User-owned LawSpec adapter.
package ordering

// FirstLine returns the first element of a non-empty list.
func FirstLine(value0 NonEmptyList[int32]) int32 {
	return value0.(NonEmptyListNonEmptyList[int32]).Value[0]
}

// ValidateOrder checks the raw order and wraps its values.
func ValidateOrder(value0 UnvalidatedOrder) LawSpecEither[OrderError, ValidatedOrder] {
	input := value0.(UnvalidatedOrderUnvalidatedOrder)
	if len(input.Id) == 0 {
		return LawSpecLeft[OrderError, ValidatedOrder](OrderErrorInvalidOrderId{})
	}
	if !(input.Quantity >= 1 && input.Quantity <= 1000) {
		return LawSpecLeft[OrderError, ValidatedOrder](OrderErrorInvalidQuantity{})
	}
	return LawSpecRight[OrderError, ValidatedOrder](ValidatedOrderValidatedOrder{
		Id: OrderIdOrderId{Value: input.Id}, Quantity: UnitQuantityUnitQuantity{Value: input.Quantity}})
}

// PriceOrder prices a validated order.
func PriceOrder(value0 ValidatedOrder) LawSpecEither[OrderError, PricedOrder] {
	order := value0.(ValidatedOrderValidatedOrder)
	total := int64(order.Quantity.(UnitQuantityUnitQuantity).Value) * 25
	if total > 20000 {
		return LawSpecLeft[OrderError, PricedOrder](OrderErrorPriceTooHigh{})
	}
	return LawSpecRight[OrderError, PricedOrder](PricedOrderPricedOrder{Id: order.Id, Quantity: order.Quantity, Total: total})
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
