// Application code bound in lawspec.edn: the till's money type, its
// production handler, a payment function and the errors it throws.
public enum Till {
    /// The application's own money type.
    public struct Cash: Sendable {
        public var cents: Int64
        public init(cents: Int64) { self.cents = cents }
    }

    /// The application's error for a declined card.
    public struct CardDeclined: Error, CustomStringConvertible {
        public init() {}
        public var description: String { "declined" }
    }

    /// The application's error for an amount it cannot take.
    public struct BadAmount: Error, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    /// A till that keeps what it takes: the production handler, in the application's types.
    public final class NativeTill: LawSpec.Abilities.ExampleTill.Drawer {
        private var taken: Int64 = 0

        public init() {}

        public func take(_ money: Cash) -> Cash {
            taken += money.cents
            return Cash(cents: money.cents)
        }

        public func opening() -> Cash { Cash(cents: 0) }
    }

    /// Payments: a bound adapter. It gets its till as the generated protocol.
    public enum Payments {
        public static func pay(_ till: any LawSpec.Abilities.ExampleTill.Drawer, _ cents: Int64) throws -> Cash {
            if cents < 0 { throw BadAmount("negative") }
            if cents > 1000 { throw CardDeclined() }
            return Cash(cents: till.take(Cash(cents: cents)).cents)
        }
    }
}
