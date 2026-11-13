// User-owned LawSpec adapter.
package domain

// Convert implements convert :: (shop.domain::type::Currency -> (shop.domain::type::Money ->
// shop.domain::type::Money)).
func Convert(currency1 ShopDomainCurrency, money1 Money) Money {
	panic("convert")
}
