module Example.Gadt
open LawSpec.Data
let describe (value: Shown) : string =
    match value with
    | Shown.Shown(_, witness) -> witness
