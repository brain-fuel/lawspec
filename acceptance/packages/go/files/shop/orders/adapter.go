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
	total := value0.Price.Cents * int64(value0.Quantity.Value)
	if total > 100000000 {
		total = 100000000
	}
	return Money{Currency: value0.Price.Currency, Cents: total}
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

// Classify uses version 2 of shop.tax: no tax on nothing, the high band from
// 100.00.
func Classify(value0 int64) ShopTaxV2x0x0RatesBand {
	if value0 <= 0 {
		return ShopTaxV2x0x0RatesBandZero{}
	}
	if value0 < 10000 {
		return ShopTaxV2x0x0RatesBandLow{}
	}
	return ShopTaxV2x0x0RatesBandHigh{}
}
