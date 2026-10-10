// User-owned LawSpec adapter: the portable generator under test.
// ref:DEC-portable-seeded-generation ref:DEC-acceptance-with-mutants
module Example.Generation

open LawSpec.Runtime

let generated (text: string) (seed: uint64) (size: int) (count: int) : string list =
    Descriptors.generated text (bigint seed) size count

let shrunk (text: string) (seed: uint64) (size: int) : string list =
    Descriptors.shrunk text (bigint seed) size
