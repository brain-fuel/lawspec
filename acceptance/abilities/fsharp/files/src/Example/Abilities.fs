// User-owned LawSpec adapter: a native Gateway handler and a native adapter
// that uses Gateway through the handler it is given.
// ref:DEC-acceptance-with-mutants
module Example.Abilities

open LawSpec.Abilities.ExampleAbilities
open LawSpec.Data

/// (Int32 -> Bool)
let charge (gateway: IGateway) (value0: int) : bool =
    match gateway.Authorize value0 with
    | Approved cents -> gateway.Capture(cents).Cents = value0
    | Declined -> false

/// The native handler of Gateway: authorize, capture, fee.
let gatewayHandler () : IGateway =
    { new IGateway with
        member _.Authorize(cents) = if cents < 0 then Declined else Approved cents
        member _.Capture(cents) = { Cents = cents }
        member _.Fee() = 25 }
