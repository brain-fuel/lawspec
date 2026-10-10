// User-owned LawSpec adapter. ref:DEC-acceptance-with-mutants
module Example.Limits

open System.Threading
open System.Threading.Tasks
open LawSpec
open LawSpec.Data

let admitTicket (ticket: Ticket) : Either<string, Ticket> = Either.Right ticket

let reserveSeat (ticket: Ticket) : Either<string, Ticket> = Either.Right ticket

let chargeCard (ticket: Ticket) : Either<string, Ticket> =
    if ticket.Number < 0L then Either.Left "declined" else Either.Right ticket

let releaseSeat (_: Ticket) : bool = true

let private quotes = ref 0L

let resetQuotes () = Interlocked.Exchange(&quotes.contents, 0L) |> ignore

// Ticket -1's quote takes 600ms.
let fetchQuote (ticket: Ticket) : Task<Either<string, Ticket>> =
    task {
        if ticket.Number = -1L then do! Task.Delay 600
        return Either.Right ticket
    }

// Ticket -2's first quote (and every other one after) stalls.
let hedgeQuote (ticket: Ticket) : Task<Either<string, Ticket>> =
    task {
        if ticket.Number = -2L && Interlocked.Increment(&quotes.contents) % 2L = 1L then do! Task.Delay 600
        return Either.Right ticket
    }
