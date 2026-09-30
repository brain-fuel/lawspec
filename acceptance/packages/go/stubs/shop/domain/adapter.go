// User-owned LawSpec adapter.
package domain

// Convert implements convert :: (shop.domain::type::Currency -> (shop.domain::type::Money ->
// shop.domain::type::Money)).
func Convert(value0 ShopDomainCurrency, value1 Money) Money {
	panic("convert")
}
