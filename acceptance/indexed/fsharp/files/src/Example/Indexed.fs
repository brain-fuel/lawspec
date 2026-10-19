// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
module Example.Indexed

open LawSpec.Data

let replicate (value0: bigint) (value1: sbyte) : Vec<sbyte> =
    let mutable result = VNil
    let mutable i = 0I
    while i < value0 do
        result <- VCons({ Head = value1; Tail = result })
        i <- i + 1I
    result

let rec append (value0: Vec<sbyte>) (value1: Vec<sbyte>) : Vec<sbyte> =
    match value0 with
    | VCons({ Head = head; Tail = tail }) -> VCons({ Head = head; Tail = append tail value1 })
    | VNil -> value1

let rec zip (value0: Vec<sbyte>) (value1: Vec<bool>) : Vec<bool> =
    match value0, value1 with
    | VCons({ Head = _; Tail = tail0 }), VCons({ Head = head1; Tail = tail1 }) -> VCons({ Head = head1; Tail = zip tail0 tail1 })
    | _ -> VNil

let rec flatten (value0: Tree<sbyte>) : Vec<sbyte> =
    match value0 with
    | Tip -> VNil
    | Bin({ Left = left; Right = right; Value = value }) ->
        let right = VCons({ Head = value; Tail = flatten right })
        append (flatten left) right
