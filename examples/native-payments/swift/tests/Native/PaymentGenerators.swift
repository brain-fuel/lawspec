// Prices the application considers representative: 1.00 to 2.00 euros.
import App
import LawSpecRuntime
import LawSpecTesting

enum PaymentGenerators {
    static func prices() -> Gen<PaymentsDomain.Price> {
        Gens.range(100, 200).map { cents in
            PaymentsDomain.Price(major: ExactDecimal(coefficient: BigInt(cents), exponent: -2), unit: .euros)
        }
    }
}
