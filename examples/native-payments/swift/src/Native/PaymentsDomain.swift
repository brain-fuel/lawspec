// Application types, independent of generated LawSpec domain declarations.
import LawSpecRuntime

public enum PaymentsDomain {
    public enum CurrencyCode: Sendable {
        case dollars
        case euros
        case pounds
    }

    public struct Price: Sendable {
        public var major: ExactDecimal
        public var unit: CurrencyCode

        public init(major: ExactDecimal, unit: CurrencyCode) {
            self.major = major
            self.unit = unit
        }
    }

    public enum PaymentStatus: Sendable {
        case settled(price: Price)
        case rejected(explanation: String)
    }

    private static let fee = ExactDecimal(coefficient: 2, exponent: -1)

    public static func applyFee(_ price: Price) -> Price {
        Price(major: price.major + fee, unit: price.unit)
    }

    public static func restore(_ payment: PaymentStatus) -> PaymentStatus { payment }

    public static func store(_ payments: [PaymentStatus?]) -> [PaymentStatus?] { payments }
}
