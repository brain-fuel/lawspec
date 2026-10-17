module IndexPaths
open LawSpec.Runtime
module S = LawSpec.Runtime.Schema
let chain = Named("Chain", [])
let inner = Named("lawspec::structural::record::inner", [])
let outer = Named("lawspec::structural::record::outer", [])
let wrapper = Named("Wrapper", [])
let ctor tag fields indices = { S.constructor tag fields with Indices=indices }
let definition name constructors : S.DataDefinition = { Name=name; Parameters=0; Constructors=constructors; Handle=false }
let definitions = [
    definition "Chain" [ctor "Stop" [] ["c0";"c10"]; ctor "Next" ["tail",chain] ["+ f0 c1";"+ f0.1 c1"]]
    definition "lawspec::structural::record::inner" [ctor "Inner" ["rest",chain] []]
    definition "lawspec::structural::record::outer" [ctor "Outer" ["child",inner;"sibling",chain] []]
    definition "Wrapper" [ctor "Wrap" ["payload",outer] ["p0/0/0.0";"p0/0/0.1";"== p0/0/0.1 + p0/1.0 c10";"== p0/0/0.0 p0/1.0";">= p0/0/0.0 c1"]]
]
let stop = Data("Stop", [])
let one = Data("Next", [stop])
let two = Data("Next", [one])
let wrapped left right = Data("Wrap", [Data("Outer", [Data("Inner", [left]); right])])
[<EntryPoint>]
let main _ =
    for bits in [32;64] do
        let schema = S.create definitions [] bits
        let good = S.validate (wrapped two two) wrapper schema
        if S.index good wrapper 0 schema <> bigint 2 || S.index good wrapper 1 schema <> bigint 12 then failwith "wrong index path"
        for bad in [wrapped two one; wrapped stop stop] do
            let mutable rejected = false
            try S.validate bad wrapper schema |> ignore
            with :? LawSpecException as error -> rejected <- error.Code = "RefinementViolation"
            if not rejected then failwith "accepted mismatched or underflowing indices"
    printfn "index path conformance: .NET, both widths"
    0
