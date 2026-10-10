// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
module Example.Refinements

let add (a: sbyte) (b: sbyte) : bigint = bigint a + bigint b
let successor (a: sbyte) : bigint = bigint a + 1I
let count (text: string) : bigint = bigint (Seq.length (text.EnumerateRunes()))
let preserve (a: uint64) : bigint = bigint a
let positive (a: sbyte) : sbyte = a
let abstractEcho (a: bigint) : bigint = a
