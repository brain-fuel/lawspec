/// Prices the application considers representative: 1.00 to 2.00 euros.
module Domain.PaymentGenerators

open LawSpec.Testing
open Domain.PaymentsDomain

let prices () : Gen<Price> =
    Gen.range 100 200
    |> Gen.map (fun cents -> { major = { Coefficient = bigint cents; Exponent = -2 }; unit = Euros })
