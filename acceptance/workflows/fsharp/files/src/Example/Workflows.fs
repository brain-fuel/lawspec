// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
module Example.Workflows

open System.Threading.Tasks
open LawSpec
open LawSpec.Data

let audit (_: Account) : bool = true

let waitlist (error: SignupError) : Either<SignupError, Account> =
    if error = Unavailable then Either.Right { Name = "waitlist"; Age = 18; Level = 0 } else Either.Left error

let checkName (signup: Signup) : Either<SignupError, Signup> =
    if signup.Name = "" then Either.Left MissingName else Either.Right signup

let checkAge (signup: Signup) : Either<string, Signup> =
    if signup.Age < 18 then Either.Left "too young" else Either.Right signup

let openAccount (signup: Signup) : Either<SignupError, Account> =
    if signup.Name = "taken" then Either.Left Unavailable else Either.Right { Name = signup.Name; Age = signup.Age; Level = 1 }

/// Each check records when it fails, so approvalErrors can tell completion
/// order from declaration order.
let finished = System.Collections.Concurrent.ConcurrentQueue<string>()

/// Order -1's slow checks record when they ran, so approvedQuickly can tell
/// whether they ran at the same time. The queue is never cleared, so tests
/// running at once cannot erase each other's.
let spans = System.Collections.Concurrent.ConcurrentQueue<int64 * int64>()

/// Whether two slow checks that started at or after since overlapped in time.
let overlapped (since: int64) : bool =
    let ran = spans.ToArray() |> Array.filter (fun (start, _) -> start >= since)
    seq { for i in 0 .. ran.Length - 1 do for j in i + 1 .. ran.Length - 1 -> ran[i], ran[j] }
    |> Seq.exists (fun ((a, b), (c, d)) -> a < d && c < b)

let private check (order: Order) (milliseconds: int) (problem: string) : Task<Either<string, Order>> =
    task {
        if order.Number = -1L then
            let start = System.Diagnostics.Stopwatch.GetTimestamp()
            do! Task.Delay milliseconds
            spans.Enqueue((start, System.Diagnostics.Stopwatch.GetTimestamp()))
        if order.Number >= 0L then return Either.Right order
        else
            finished.Enqueue problem
            return Either.Left problem
    }

// Order -1's stock check takes 400ms; a negative order has no stock.
let checkStock (order: Order) : Task<Either<string, Order>> = check order 400 "no stock"

// Order -1's credit check takes 250ms; a negative order has no credit.
let checkCredit (order: Order) : Task<Either<string, Order>> = check order 250 "no credit"
