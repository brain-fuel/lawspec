/// Black-box conformance of the shared .NET finite-cover runtime.
/// ref:DEC-planned-generation
module FiniteCases

open System
open System.Numerics
open LawSpec.Runtime
open LawSpec.Testing

let ensure condition =
    if not condition then
        failwith "finite-cover conformance"

let scalar (n: int) = Value.Int(BigInteger n)

let read =
    function
    | [ Value.Int value ] -> value
    | _ -> failwith "integer input"

let symbols () = Scalar.SymbolContext()
let one = Finite.finish 1

let range (first: int) (last: int) =
    Finite.range "Integer" (BigInteger first) (BigInteger last)

let branch domain rest = Finite.branch domain rest
let alternatives branches = Finite.choices branches

let main () =
    let cover =
        alternatives [ branch (range 1 3) (Finite.finish 2); branch (range 8 9) one ]

    ensure (Finite.count cover = BigInteger 8)
    ensure ([ for index in 1..8 -> Finite.at cover (symbols ()) index |> read ] = [ 1I; 1I; 2I; 2I; 3I; 3I; 8I; 9I ])

    let correlated =
        alternatives
            [
                branch (range 1 1) (alternatives [ branch (range 3 4) one ])
                branch (range 2 2) (alternatives [ branch (range 9 9) one ])
            ]

    ensure (
        [ for index in 1..3 -> Finite.at correlated (symbols ()) index ] =
            [ [ scalar 1; scalar 3 ]; [ scalar 1; scalar 4 ]; [ scalar 2; scalar 9 ] ]
    )

    let maximum = BigInteger.Parse "18446744073709551615"

    let huge =
        alternatives [ branch (Finite.range "UInt64" (maximum - 2I) maximum) one ]

    ensure (Finite.at huge (symbols ()) 3 |> read = maximum)
    let empty = alternatives [ branch (range 3 2) one; branch (range 4 4) one ]
    ensure (Finite.count empty = 1I && Finite.at empty (symbols ()) 1 = [ scalar 4 ])
    let mutable calls = 0

    let deferred =
        Finite.values
            [
                fun _ ->
                    calls <- calls + 1
                    Value.Bytes [| 1uy |]
            ]

    let lazyCover = alternatives [ branch deferred (Finite.finish 2) ]
    ensure (calls = 0)

    let bytes =
        function
        | [ Value.Bytes bytes ] -> bytes
        | _ -> failwith "bytes input"

    let first = Finite.at lazyCover (symbols ()) 1 |> bytes
    first[0] <- 2uy
    ensure ((Finite.at lazyCover (symbols ()) 2 |> bytes)[0] = 1uy && calls = 2)

    let symbol =
        Finite.values [ fun context -> Scalar.symbol context "shared" "same symbol" ]

    let symbolCover =
        alternatives [ branch symbol (alternatives [ branch symbol one ]) ]

    let identities =
        function
        | [ Value.Symbol(a, _); Value.Symbol(b, _) ] ->
            ensure (obj.ReferenceEquals(a, b))
            a
        | _ -> failwith "symbol input"

    let firstId = Finite.at symbolCover (symbols ()) 1 |> identities
    let secondId = Finite.at symbolCover (symbols ()) 1 |> identities
    ensure (not (obj.ReferenceEquals(firstId, secondId)))

    for index in [ 0; 9 ] do
        let rejected =
            try
                Finite.at cover (symbols ()) index |> ignore
                false
            with :? ArgumentException ->
                true

        ensure rejected

    let rows = Finite.rows "unit::law" "spec.lawspec:7" 3 |> Seq.toList

    ensure (
        rows.Length = 3
        && rows[2].Data = 3
        && rows[2].TestDisplayName = "unit::law boundary 3 — spec.lawspec:7"
    )

    let mutable observations = 0

    Finite.checkAll "count" cover (symbols ()) (fun _ ->
        observations <- observations + 1
        Value.Bool true)

    ensure (observations = 8)

    let failed =
        try
            Finite.check "count" 2 [ scalar 1 ] (fun _ -> Value.Bool false)
            false
        with :? LawSpecException as error ->
            error.Code = "BoundaryFailed" && error.Message.Contains "boundary 2 (1)"

    ensure failed
    printfn "Finite .NET cover conformance passed"

main ()
