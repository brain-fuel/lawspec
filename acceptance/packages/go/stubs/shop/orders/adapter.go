// User-owned LawSpec adapter.
package orders

// Settlement implements settlement :: (shop.orders::type::Currency -> shop.domain::type::Currency).
func Settlement(currency1 ShopOrdersCurrency) ShopDomainCurrency {
	panic("settlement")
}

// LineTotal implements lineTotal :: (shop.orders::type::Line -> shop.domain::type::Money).
func LineTotal(line1 Line) Money {
	panic("lineTotal")
}

// Cheaper implements cheaper :: (Int64 -> (Int64 -> Int64)).
func Cheaper(int64_1 int64, int64_2 int64) int64 {
	panic("cheaper")
}

// RoundDown implements roundDown :: (Int64 -> Int64).
func RoundDown(int64_1 int64) int64 {
	panic("roundDown")
}

// Classify implements classify :: (Int64 -> shop.tax.v2x0x0.rates::type::Band).
func Classify(int64_1 int64) ShopTaxV2x0x0RatesBand {
	panic("classify")
}
