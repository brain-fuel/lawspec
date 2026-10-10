// User-owned LawSpec adapter. ref:REQ-harness-units ref:DEC-tests-cite-requirements
module Example.Harness

open LawSpec.Abilities.ExampleHarness
open LawSpec.Data

let discount (order: Order) : int = if order.Items > 10 then order.Total / 10 else 0

let roundCents (cents: int) : int = (cents + 4) / 10 * 10

let book (ledger: ILedger) (cents: int) : bool = ledger.Accept cents

let ledgerHandler () : ILedger =
    { new ILedger with
        member _.Accept(cents) = cents > 0 }
