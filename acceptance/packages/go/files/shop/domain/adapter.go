// User-owned LawSpec adapter.
package domain

// Convert re-denominates money at a one-to-one rate.
func Convert(value0 ShopDomainCurrency, value1 Money) Money {
	return Money{Currency: value0, Cents: value1.Cents}
}
