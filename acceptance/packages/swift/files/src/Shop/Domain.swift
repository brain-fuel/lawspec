// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Shop.Domain {
    /// One-to-one rates keep the example exact.
    static func convert(_ currency: ShopDomainCurrency, _ money: Money) -> Money {
        var converted = money
        converted.currency = currency
        return converted
    }
}
