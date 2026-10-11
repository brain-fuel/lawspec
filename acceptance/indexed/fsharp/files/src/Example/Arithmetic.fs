// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
module Example.Arithmetic

open LawSpec.Data

let rec private length (row: Row) : int64 =
    match row with
    | End -> 0L
    | Cell(_, tail) -> 1L + length tail

let rec mirror (value0: Perfect) : Perfect =
    match value0 with
    | Leaf _ -> value0
    | Node(left, right) -> Node(mirror right, mirror left)

let area (value0: Grid) : bigint = bigint (length value0.Rows * length value0.Columns)

let duplicate (value0: Row) : Halves = { Front = value0; Back = value0 }

let countPairs (value0: Row) : Pairs = { Pairs.Items = value0 }

let dropFirst (value0: Row) : Rest = { Rest.Items = value0 }
