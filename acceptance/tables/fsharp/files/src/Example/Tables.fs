// User-owned LawSpec adapters for the tables example.
// ref:DEC-acceptance-with-mutants
module Example.Tables

let shippingCost (weight: int) (distance: int) : int = weight * distance + 5 * weight

let label (parcel: int) : string = sprintf "parcel %d" parcel
