// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
module Example.Gadt

open LawSpec.Data

// F# unions cannot refine their type arguments per case, so a match ends with
// a case no value of the refined type has.
let rec evalNumber (value0: Expr<bigint>) : bigint =
    match value0 with
    | Number n -> n
    | Plus(left, right) -> evalNumber left + evalNumber right
    | _ -> invalidArg "value0" "not an Expr<bigint>"

let rec evalTruth (value0: Expr<bool>) : bool =
    match value0 with
    | Truth b -> b
    | Same(left, right) -> evalNumber left = evalNumber right
    | Negate operand -> not (evalTruth operand)
    | _ -> invalidArg "value0" "not an Expr<bool>"

// Both's fields have the types its equation binds (Expr<bigint> and
// Expr<bool> here); F# types them Expr<Value>, so they are retyped through
// their portable value.
let private retype (codec: LawSpec.Runtime.Codec<'T>) (value: Expr<LawSpec.Runtime.Value>) : Expr<'T> =
    (Codecs.expr codec).ToNative((Codecs.expr LawSpec.Runtime.Codec.portable).FromNative value)

let evalPair (value0: Expr<Pair<bigint, bool>>) : Pair<bigint, bool> =
    match value0 with
    | Both(first, second) ->
        { First = evalNumber (retype LawSpec.Runtime.Codec.bigint first)
          Second = evalTruth (retype LawSpec.Runtime.Codec.bool second) }
    | _ -> invalidArg "value0" "not an Expr<Pair<bigint, bool>>"

let fold (value0: Expr<bigint>) : Expr<bigint> = Number(evalNumber value0)

let describe (value0: Shown) : string =
    match value0 with
    | Shown.Shown(_, witness) -> witness
