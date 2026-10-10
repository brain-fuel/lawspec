// User-owned LawSpec adapter. class is an F# keyword, so the adapter is class_.
// ref:DEC-acceptance-with-mutants
module Example.Keywords

let class_ (value0: bigint) : bigint = value0 <<< 1
