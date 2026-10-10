// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
module Example.Indexed

open LawSpec.Data

let replicate (value0: bigint) (value1: sbyte) : Vec<sbyte> =
    let mutable result = VNil
    let mutable i = 0I
    while i < value0 do
        result <- VCons(value1, result)
        i <- i + 1I
    result

let rec append (value0: Vec<sbyte>) (value1: Vec<sbyte>) : Vec<sbyte> =
    match value0 with
    | VCons(head, tail) -> VCons(head, append tail value1)
    | VNil -> value1

let rec zip (value0: Vec<sbyte>) (value1: Vec<bool>) : Vec<bool> =
    match value0, value1 with
    | VCons(_, tail0), VCons(head1, tail1) -> VCons(head1, zip tail0 tail1)
    | _ -> VNil

let rec flatten (value0: Tree<sbyte>) : Vec<sbyte> =
    match value0 with
    | Tip -> VNil
    | Bin(left, value, right) ->
        let right = VCons(value, flatten right)
        append (flatten left) right
