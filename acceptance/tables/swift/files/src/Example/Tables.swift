// User-owned LawSpec adapters for the tables example.
// ref:DEC-acceptance-with-mutants
import LawSpecRuntime

extension Example.Tables {
    static func shippingCost(_ weight: Int32, _ distance: Int32) -> Int32 { weight * distance + 5 * weight }

    static func label(_ parcel: Int32) -> String { "parcel \(parcel)" }
}
