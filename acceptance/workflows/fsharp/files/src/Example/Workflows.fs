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

let private check (order: Order) (milliseconds: int) (problem: string) : Task<Either<string, Order>> =
    task {
        if order.Number = -1L then do! Task.Delay milliseconds
        if order.Number >= 0L then return Either.Right order
        else
            finished.Enqueue problem
            return Either.Left problem
    }

// Order -1's stock check takes 400ms; a negative order has no stock.
let checkStock (order: Order) : Task<Either<string, Order>> = check order 400 "no stock"

// Order -1's credit check takes 250ms; a negative order has no credit.
let checkCredit (order: Order) : Task<Either<string, Order>> = check order 250 "no credit"
