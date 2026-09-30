// User-owned LawSpec adapter.
package orders

// Settlement implements settlement :: (shop.orders::type::Currency -> shop.domain::type::Currency).
func Settlement(value0 ShopOrdersCurrency) ShopDomainCurrency {
	panic("settlement")
}

// LineTotal implements lineTotal :: (shop.orders::type::Line -> shop.domain::type::Money).
func LineTotal(value0 Line) Money {
	panic("lineTotal")
}

// Cheaper implements cheaper :: (Int64 -> (Int64 -> Int64)).
func Cheaper(value0 int64, value1 int64) int64 {
	panic("cheaper")
}

// RoundDown implements roundDown :: (Int64 -> Int64).
func RoundDown(value0 int64) int64 {
	panic("roundDown")
}
