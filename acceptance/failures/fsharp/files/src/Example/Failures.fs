// User-owned LawSpec adapter: native adapters that fail with a Result, and
// the native Gateway handler.
// ref:DEC-acceptance-with-mutants
module Example.Failures

open LawSpec.Abilities.ExampleFailures
open LawSpec.Data

/// (Int32 -> Int32)
let refund (value0: int) : Result<int, PaymentError> =
    if value0 > 5000 then Error(TooLarge 5000) else Ok value0

/// (Int32 -> Int32)
let settle (value0: int) : System.Threading.Tasks.Task<Result<int, PaymentError>> =
    task {
        do! System.Threading.Tasks.Task.Yield()
        if value0 < 0 then return Error Blocked
        elif value0 = 0 then return Error(Declined { Message = "there is nothing to settle" })
        else return Ok value0
    }

/// The native handler of Gateway: decide.
let gatewayHandler () : IGateway =
    { new IGateway with
        member _.Decide(value0) =
            if value0 < 0 then Block
            elif value0 % 2 = 1 then Decline "an odd amount"
            else Approve }
