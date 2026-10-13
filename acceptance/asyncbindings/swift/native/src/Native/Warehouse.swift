// Application code the warehouse adapters are bound to: some of it
// asynchronous, as a real service client would be.
public enum Warehouse {
    public enum Stock {
        static func price(_ sku: String) -> Int32 {
            sku == "free" ? 0 : Int32(sku.unicodeScalars.count % 100)
        }

        public static func priceOf(_ sku: String) async -> Int32 {
            await Task.yield()
            return price(sku)
        }

        public static func quoteOf(_ sku: String) -> Int32 { price(sku) }
    }

    /// A stock count that several callers may change.
    public actor Shelf {
        private var total: Int64 = 0

        public init() {}

        public func restock(_ amount: Int32) async {
            total += Int64(amount)
        }

        public func count() async -> Int64 { total }
    }
}
