// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Shop.Orders {
    static func settlement(_ currency: ShopOrdersCurrency) -> ShopDomainCurrency {
        switch currency {
        case .usd: return .usd
        case .gbp: return .eur
        }
    }

    static func lineTotal(_ line: Line) -> Money {
        let count = Int64(line.quantity.value)
        return Money(currency: line.price.currency, cents: min(line.price.cents * count, 100_000_000))
    }

    static func cheaper(_ a: Int64, _ b: Int64) -> Int64 { min(a, b) }

    static func roundDown(_ cents: Int64) -> Int64 { cents - cents % 100 }

    /// Version 2 of shop.tax: no tax on nothing, the high band from 100.00.
    static func classify(_ cents: Int64) -> ShopTaxV2x0x0RatesBand {
        if cents <= 0 { return .zero }
        if cents < 10000 { return .low }
        return .high
    }
}
