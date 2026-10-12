// User-owned LawSpec adapter: async adapters are async functions.
// ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Orders {
    private static func priceOf(_ sku: String) -> Int32 {
        sku == "free" ? 0 : Int32(sku.unicodeScalars.count % 100)
    }

    static func price(_ sku: String) async -> Int32 {
        await Task.yield()
        return priceOf(sku)
    }

    static func stock(_ sku: String) async -> Int32 {
        await Task.yield()
        return Int32(sku.unicodeScalars.count)
    }

    static func quote(_ sku: String) -> Int32 { priceOf(sku) }
}
