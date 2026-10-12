/// Prices the application considers representative: 1.00 to 2.00 euros.
module Domain.PaymentGenerators

open FsCheck
open FsCheck.FSharp
open Domain.PaymentsDomain

let prices () : Arbitrary<Price> =
    Gen.choose (100, 200)
    |> Gen.map (fun cents -> { major = { Coefficient = bigint cents; Exponent = -2 }; unit = Euros })
    |> Arb.fromGen
