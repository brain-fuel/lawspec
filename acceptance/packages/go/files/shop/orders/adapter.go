// User-owned LawSpec adapter.
package orders

// Settlement maps a local currency to the currency it settles in.
func Settlement(value0 ShopOrdersCurrency) ShopDomainCurrency {
	if _, ok := value0.(ShopOrdersCurrencyUsd); ok {
		return ShopDomainCurrencyUsd{}
	}
	return ShopDomainCurrencyEur{}
}

// LineTotal prices a line, capped at the largest amount of Cents.
func LineTotal(value0 Line) Money {
	line := value0.(LineLine)
	price := line.Price.(MoneyMoney)
	total := price.Cents * int64(line.Quantity.(QuantityQuantity).Value)
	if total > 100000000 {
		total = 100000000
	}
	return MoneyMoney{Currency: price.Currency, Cents: total}
}

// Cheaper returns the smaller price.
func Cheaper(value0 int64, value1 int64) int64 {
	if value0 < value1 {
		return value0
	}
	return value1
}

// RoundDown rounds a price down to whole dollars.
func RoundDown(value0 int64) int64 {
	return value0 - value0%100
}
