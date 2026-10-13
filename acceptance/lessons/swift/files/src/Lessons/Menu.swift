// User-owned LawSpec adapter.
import LawSpecRuntime

extension Lessons.Menu {
    static func priceOf(_ value0: Item) -> Int64 {
        switch value0 {
        case .espresso: return 250
        case .latte: return 350
        case .tea: return 300
        }
    }

    static func cheapest(_ value0: Int64, _ value1: Int64) -> Int64 { min(value0, value1) }
}
